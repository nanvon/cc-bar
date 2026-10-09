import Foundation
import XCTest
@testable import CCBar

final class QuotaAlertTests: XCTestCase {
    private let start = Date(timeIntervalSince1970: 1_790_000_000)

    private func evaluate(
        _ remaining: Double, previous: QuotaAlertRecord? = nil, reset: Date? = nil,
        time: Date? = nil, threshold: Int = 20, id: UUID = UUID(), baseline: Bool = false,
        seconds: Int? = 18_000
    ) -> QuotaAlertPolicy.Result? {
        QuotaAlertPolicy.evaluate(
            previous: previous, window: QuotaWindow(usedPercent: 100 - remaining, resetsAt: reset, windowSeconds: seconds),
            kind: .fiveHour, threshold: threshold, observationID: id, now: time ?? start, baseline: baseline
        )
    }

    private func occupied(reset: Date? = nil, threshold: Int = 20) -> QuotaAlertRecord {
        var record = evaluate(18, reset: reset)!.record
        record.alertedThreshold = threshold
        record.submission = QuotaAlertSubmission(id: UUID(), status: .accepted, submittedAt: start)
        return record
    }

    func testStrictThresholdAndInvalidValues() {
        XCTAssertFalse(evaluate(20)!.shouldAlert)
        XCTAssertTrue(evaluate(19.9)!.shouldAlert)
        XCTAssertTrue(evaluate(0)!.shouldAlert)
        for used in [Double.nan, .infinity, -1, 101] {
            XCTAssertNil(QuotaAlertPolicy.evaluate(
                previous: nil, window: QuotaWindow(usedPercent: used), kind: .fiveHour,
                threshold: 20, observationID: UUID(), now: start
            ))
        }
        XCTAssertNil(QuotaAlertPolicy.evaluate(
            previous: nil, window: QuotaWindow(usedPercent: 99), kind: .unknown,
            threshold: 20, observationID: UUID(), now: start
        ))
        XCTAssertEqual(QuotaAlertPreferences.validThreshold(0), 20)
        XCTAssertEqual(QuotaAlertPreferences.validThreshold(23), 20)
    }

    func testSameCycleNeverRealertsEvenAfterTemporaryRecovery() {
        let anchor = start.addingTimeInterval(3600)
        var record = occupied(reset: anchor)
        for (index, remaining) in [18.0, 10, 0, 22, 90, 18].enumerated() {
            let result = evaluate(remaining, previous: record, reset: anchor,
                                  time: start.addingTimeInterval(Double(index) * 120))!
            XCTAssertFalse(result.shouldAlert)
            XCTAssertEqual(result.record.cycleID, record.cycleID)
            record = result.record
        }
    }

    func testDriftUsesFixedAnchorAndExpiredAnchorAllowsNewCycle() {
        let anchor = start.addingTimeInterval(3600)
        let record = occupied(reset: anchor)
        for offset in stride(from: 0.0, through: 2700.0, by: 600.0) {
            let result = evaluate(5, previous: record, reset: anchor.addingTimeInterval(offset))!
            XCTAssertEqual(result.record.anchor, anchor)
            XCTAssertFalse(result.shouldAlert)
        }
        let result = evaluate(5, previous: record, reset: anchor.addingTimeInterval(18_000),
                              time: anchor.addingTimeInterval(1))!
        XCTAssertTrue(result.shouldAlert)
        XCTAssertNotEqual(result.record.cycleID, record.cycleID)
    }

    func testEarlyResetRequiresTwoIndependentRecoveryObservations() {
        let anchor = start.addingTimeInterval(3600)
        let nextReset = anchor.addingTimeInterval(3600)
        let record = occupied(reset: anchor)
        XCTAssertFalse(evaluate(5, previous: record, reset: nextReset)!.shouldAlert)
        let firstID = UUID()
        let first = evaluate(30, previous: record, reset: nextReset, id: firstID)!.record
        let duplicate = evaluate(30, previous: first, reset: nextReset,
                                 time: start.addingTimeInterval(120), id: firstID)!.record
        XCTAssertEqual(duplicate.cycleID, record.cycleID)
        let tooSoon = evaluate(30, previous: first, reset: nextReset, time: start.addingTimeInterval(59))!.record
        XCTAssertEqual(tooSoon.cycleID, record.cycleID)
        let recovered = evaluate(30, previous: first, reset: nextReset, time: start.addingTimeInterval(60))!.record
        XCTAssertNotEqual(recovered.cycleID, record.cycleID)
        XCTAssertTrue(evaluate(5, previous: recovered, reset: nextReset, time: start.addingTimeInterval(180))!.shouldAlert)
    }

    func testUnknownTimeRecoveryAndThresholdChanges() {
        let record = occupied()
        XCTAssertFalse(evaluate(0, previous: record)!.shouldAlert)
        let first = evaluate(30, previous: record)!.record
        let changed = evaluate(30, previous: first, time: start.addingTimeInterval(120), threshold: 10)!.record
        XCTAssertEqual(changed.cycleID, record.cycleID)
        let low = evaluate(5, previous: changed, time: start.addingTimeInterval(240), threshold: 10)!.record
        XCTAssertNil(low.recovery)
        let high = evaluate(30, previous: low, time: start.addingTimeInterval(360), threshold: 10)!.record
        let recovered = evaluate(30, previous: high, time: start.addingTimeInterval(480), threshold: 10)!.record
        XCTAssertTrue(evaluate(5, previous: recovered, time: start.addingTimeInterval(600), threshold: 10)!.shouldAlert)
        // 原提醒阈值仍是 40，降低设置不能把 30% 当作真实恢复。
        XCTAssertNil(evaluate(30, previous: occupied(threshold: 40), threshold: 10)!.record.recovery)
    }

    func testMissingPastEarlierAndChangedLengthDoNotUnlock() {
        let anchor = start.addingTimeInterval(3600)
        let record = occupied(reset: anchor)
        for reset in [nil, start.addingTimeInterval(-1), anchor.addingTimeInterval(-2400)] {
            XCTAssertFalse(evaluate(5, previous: record, reset: reset)!.shouldAlert)
        }
        XCTAssertEqual(evaluate(80, previous: record, reset: start.addingTimeInterval(8000), seconds: 7200)!.record.cycleID,
                       record.cycleID)
    }

    func testBaselineOccupiesOnlyLowWindows() {
        XCTAssertFalse(evaluate(5, baseline: true)!.shouldAlert)
        XCTAssertTrue(evaluate(5, baseline: true)!.record.occupied)
        let high = evaluate(80, baseline: true)!.record
        XCTAssertFalse(high.occupied)
        XCTAssertTrue(evaluate(5, previous: high)!.shouldAlert)
    }

    func testIdentityEncodingWeakMigrationAndAmbiguity() {
        let weak = QuotaAlertIdentity(accountID: " a ", userID: nil)!
        let first = QuotaAlertIdentity(accountID: "a", userID: "u1")!
        let second = QuotaAlertIdentity(accountID: "a", userID: "u2")!
        XCTAssertEqual(weak.key.count, 64)
        XCTAssertNotEqual(QuotaAlertIdentity(accountID: "a:b", userID: "c")!.key,
                          QuotaAlertIdentity(accountID: "a", userID: "b:c")!.key)
        XCTAssertNil(QuotaAlertIdentity(accountID: " ", userID: "u"))
        var payload = QuotaAlertPayload()
        payload.accounts[weak.key] = QuotaAlertAccountState(identity: weak, windows: ["fiveHour": occupied()])
        XCTAssertEqual(QuotaAlertPolicy.resolve(first, active: [weak, first], payload: &payload), first)
        XCTAssertTrue(payload.accounts[first.key]!.windows["fiveHour"]!.occupied)
        XCTAssertNil(payload.accounts[weak.key])
        XCTAssertNil(QuotaAlertPolicy.resolve(weak, active: [first, second, weak], payload: &payload))
        XCTAssertEqual(QuotaAlertPolicy.resolve(second, active: [first, second], payload: &payload), second)
        XCTAssertNil(payload.accounts[second.key])
    }

    func testProviderIdentityIsolationAndLegacyCodexDecoding() throws {
        let codex = QuotaAlertIdentity(accountID: "same-account", userID: "same-user")!
        let claude = QuotaAlertIdentity(app: .claude, accountID: "same-account", userID: "same-user")!
        XCTAssertNotEqual(codex.key, claude.key)
        XCTAssertNotEqual(codex.accountDigest, claude.accountDigest)
        var json = try JSONSerialization.jsonObject(with: JSONEncoder().encode(codex)) as! [String: Any]
        json.removeValue(forKey: "app")
        let legacy = try JSONDecoder().decode(QuotaAlertIdentity.self, from: JSONSerialization.data(withJSONObject: json))
        XCTAssertEqual(legacy, codex)
    }

    func testBillingCycleResetAcceptsMonthLengthChangeWithoutEarlyRealert() throws {
        let anchor = start.addingTimeInterval(86_400)
        let initial = try XCTUnwrap(QuotaAlertPolicy.evaluate(
            previous: nil, window: QuotaWindow(usedPercent: 95, resetsAt: anchor, windowSeconds: 31 * 86_400),
            kind: .unknown, threshold: 20, observationID: UUID(), now: start, allowBillingCycle: true
        ))
        var record = initial.record
        record.alertedThreshold = 20
        record.submission = QuotaAlertSubmission(id: UUID(), status: .accepted, submittedAt: start)
        let nextReset = anchor.addingTimeInterval(28 * 86_400)
        let early = try XCTUnwrap(QuotaAlertPolicy.evaluate(
            previous: record, window: QuotaWindow(usedPercent: 95, resetsAt: nextReset, windowSeconds: 28 * 86_400),
            kind: .unknown, threshold: 20, observationID: UUID(), now: start, allowBillingCycle: true
        ))
        XCTAssertFalse(early.shouldAlert)
        let newCycle = try XCTUnwrap(QuotaAlertPolicy.evaluate(
            previous: early.record, window: QuotaWindow(usedPercent: 105, resetsAt: nextReset, windowSeconds: 28 * 86_400),
            kind: .unknown, threshold: 20, observationID: UUID(), now: anchor.addingTimeInterval(1), allowBillingCycle: true
        ))
        XCTAssertTrue(newCycle.shouldAlert)
        XCTAssertNotEqual(newCycle.record.cycleID, record.cycleID)
    }

    @MainActor func testAllProvidersSubmitTheirOwnTitlesAndKeepIndependentRecords() async throws {
        let h = try AlertHarness()
        for app in QuotaApp.allCases {
            let snapshot: QuotaSnapshot
            switch app {
            case .codex: snapshot = h.observation().raw
            case .claude:
                snapshot = ClaudeQuotaClient.parse(root: ["five_hour": ["utilization": 95], "seven_day": ["utilization": 95]])
            case .antigravity:
                snapshot = QuotaSnapshot(app: app, primaryLimit: .standard(kind: .fiveHour, window: QuotaWindow(usedPercent: 95)), secondaryLimit: nil, planType: nil, fetchedAt: h.date)
            case .cursor:
                snapshot = CursorQuotaClient.parse(root: ["individualUsage": ["plan": ["totalPercentUsed": 95, "autoPercentUsed": 95, "apiPercentUsed": 95]]], fetchedAt: h.date)
            case .commandCode:
                snapshot = CommandCodeQuotaClient.parse(creditsRoot: ["fiveHour": ["cap": 100, "used": 95], "weekly": ["cap": 100, "used": 95], "monthlyCredits": 1], subscriptionsRoot: ["data": ["planId": "goat"]], fetchedAt: h.date).snapshot
            }
            var raw = snapshot
            raw.fetchedAt = h.date
            let observation = h.observation(snapshot: raw)
            h.service.enqueue(observation)
            h.service.enqueue(h.observation(snapshot: raw))
        }
        await h.service.waitUntilIdle()
        XCTAssertEqual(h.client.messages.count, 5)
        XCTAssertEqual(Set(h.client.messages.map(\.title)), Set(QuotaProviderDescriptor.allProviders.map { "\($0.title) quota is low" }))
        let payload = try await h.store.load(initialized: true)
        XCTAssertEqual(Set(payload.accounts.values.map { $0.identity.app }), Set(QuotaApp.allCases))
        h.makeService()
        let cursor = CursorQuotaClient.parse(root: ["individualUsage": ["plan": ["totalPercentUsed": 99]]], fetchedAt: h.date)
        h.service.enqueue(h.observation(snapshot: cursor))
        await h.service.waitUntilIdle()
        XCTAssertEqual(h.client.messages.count, 5)
    }

    @MainActor func testClaudeModelWeeklyAndInactiveWindowsAreIndependent() async throws {
        let h = try AlertHarness()
        var snapshot = ClaudeQuotaClient.parse(root: ["limits": [
            ["kind": "weekly_all", "percent": 95],
            ["kind": "weekly_scoped", "percent": 95, "scope": ["model": ["id": "opus", "display_name": "Opus"]]],
            ["kind": "weekly_scoped", "percent": 99, "is_active": false, "scope": ["model": ["id": "sonnet", "display_name": "Sonnet"]]]
        ]])
        snapshot.fetchedAt = h.date
        h.service.enqueue(h.observation(snapshot: snapshot))
        await h.service.waitUntilIdle()
        XCTAssertEqual(h.client.messages.count, 1)
        XCTAssertTrue(h.client.messages[0].body.contains("Opus Weekly quota"))
        XCTAssertFalse(h.client.messages[0].body.contains("Sonnet"))
        snapshot.modelLimits[1].isActive = true
        h.service.enqueue(h.observation(snapshot: snapshot))
        await h.service.waitUntilIdle()
        XCTAssertEqual(h.client.messages.count, 2)
        XCTAssertTrue(h.client.messages[1].body.contains("Sonnet Weekly quota"))
        XCTAssertFalse(h.client.messages[1].body.contains("Opus"))
    }

    @MainActor func testAntigravityGroupsAndFallbackUseSameWindowKeys() async throws {
        let h = try AlertHarness()
        let window = QuotaWindow(usedPercent: 95)
        let grouped = QuotaSnapshot(app: .antigravity,
            primaryLimit: QuotaLimit(id: "gemini-5h", kind: .fiveHour, window: window),
            secondaryLimit: QuotaLimit(id: "gemini-weekly", kind: .weekly, window: window),
            auxiliaryLimits: [QuotaLimit(id: "claude-5h", kind: .fiveHour, window: window), QuotaLimit(id: "claude-weekly", kind: .weekly, window: window)], planType: nil, fetchedAt: h.date)
        h.service.enqueue(h.observation(snapshot: grouped))
        await h.service.waitUntilIdle()
        let fallback = QuotaSnapshot(app: .antigravity,
            primaryLimit: .standard(kind: .fiveHour, window: window), secondaryLimit: .standard(kind: .weekly, window: window),
            geminiWindow: window, geminiWeekly: window, planType: nil, fetchedAt: h.date)
        h.service.enqueue(h.observation(snapshot: fallback))
        await h.service.waitUntilIdle()
        XCTAssertEqual(h.client.messages.count, 1)
        XCTAssertEqual(h.client.messages[0].body.components(separatedBy: "\n").count, 5)
        let payload = try await h.store.load(initialized: true)
        XCTAssertEqual(payload.accounts.values.first?.windows.count, 4)
    }

    @MainActor func testBillingCycleToggleAndOverQuotaCursorValues() async throws {
        let h = try AlertHarness()
        h.prefs.billingCycle = false
        let cursor = CursorQuotaClient.parse(root: ["individualUsage": ["plan": ["totalPercentUsed": 120, "autoPercentUsed": 95]]], fetchedAt: h.date)
        h.service.enqueue(h.observation(snapshot: cursor))
        await h.service.waitUntilIdle()
        XCTAssertTrue(h.client.messages.isEmpty)
        h.prefs.billingCycle = true
        h.service.enqueue(h.observation(snapshot: cursor))
        await h.service.waitUntilIdle()
        XCTAssertEqual(h.client.messages.count, 1)
        XCTAssertTrue(h.client.messages[0].body.contains("Total remaining 0%"))
        h.prefs.weekly = false
        var claude = ClaudeQuotaClient.parse(root: ["seven_day_opus": ["utilization": 99]])
        claude.fetchedAt = h.date
        h.service.enqueue(h.observation(snapshot: claude))
        await h.service.waitUntilIdle()
        XCTAssertEqual(h.client.messages.count, 1)
    }

    @MainActor func testRebuildBaselinesLateAppearingBillingWindows() async throws {
        let h = try AlertHarness()
        try Data("broken".utf8).write(to: h.url)
        let cursor = CursorQuotaClient.parse(root: ["individualUsage": ["plan": ["totalPercentUsed": 95]]], fetchedAt: h.date)
        h.service.enqueue(h.observation(snapshot: cursor))
        await h.service.waitUntilIdle()
        await h.service.rebuild(entries: ["primary:cursor"])
        h.service.enqueue(h.observation(snapshot: cursor))
        await h.service.waitUntilIdle()
        let more = CursorQuotaClient.parse(root: ["individualUsage": ["plan": ["totalPercentUsed": 95, "apiPercentUsed": 95]]], fetchedAt: h.date)
        h.service.enqueue(h.observation(snapshot: more))
        await h.service.waitUntilIdle()
        XCTAssertTrue(h.client.messages.isEmpty)
        let payload = try await h.store.load(initialized: true)
        XCTAssertEqual(payload.accounts.values.first?.windows.count, 2)
        XCTAssertTrue(payload.accounts.values.first!.windows.values.allSatisfy(\.occupied))
    }

    @MainActor func testV1UpgradeKeepsCodexAlreadyAlerted() async throws {
        let h = try AlertHarness()
        var payload = QuotaAlertPayload()
        payload.accounts[h.identity.key] = QuotaAlertAccountState(identity: h.identity, windows: ["fiveHour": occupied(), "weekly": occupied()])
        var root = try JSONSerialization.jsonObject(with: JSONEncoder().encode(payload)) as! [String: Any]
        root["version"] = 1
        var accounts = root["accounts"] as! [String: [String: Any]]
        var state = accounts[h.identity.key]!
        var identity = state["identity"] as! [String: Any]
        identity.removeValue(forKey: "app")
        state["identity"] = identity
        accounts[h.identity.key] = state
        root["accounts"] = accounts
        try JSONSerialization.data(withJSONObject: root).write(to: h.url)
        h.service.enqueue(h.observation())
        await h.service.waitUntilIdle()
        XCTAssertFalse(h.service.storagePaused)
        XCTAssertTrue(h.client.messages.isEmpty)
        let migrated = try await h.store.load(initialized: true)
        XCTAssertEqual(migrated.version, 2)
        XCTAssertTrue(migrated.accounts[h.identity.key]!.windows.values.allSatisfy(\.occupied))
    }

    @MainActor func testPercentRoundingDoesNotMisstateThresholdOrExhaustion() {
        let chinese: (String, String) -> String = { $1 }
        XCTAssertEqual(QuotaNotificationService.percentText(remaining: 19.99, threshold: 20, translate: chinese), "低于 20%")
        XCTAssertEqual(QuotaNotificationService.percentText(remaining: 0.01, threshold: 20, translate: chinese), "低于 0.1%")
        XCTAssertEqual(QuotaNotificationService.percentText(remaining: 0, threshold: 20, translate: chinese), "0%")
        XCTAssertEqual(QuotaNotificationService.percentText(remaining: 18.14, threshold: 20, translate: chinese), "18.1%")
    }

    @MainActor func testDisabledAndFreshnessGuardNeverQueryPermission() async throws {
        let h = try AlertHarness(enabled: false)
        h.service.enqueue(h.observation())
        await h.service.waitUntilIdle()
        XCTAssertEqual(h.client.permissionReads, 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: h.url.path))
        h.prefs.enabled = true
        h.service.enqueue(h.observation(at: h.date.addingTimeInterval(-301)))
        await h.service.waitUntilIdle()
        XCTAssertEqual(h.client.permissionReads, 0)
    }

    @MainActor func testCombinedWindowsConcurrentDuplicateAndRestart() async throws {
        let h = try AlertHarness()
        let observation = h.observation()
        h.service.enqueue(observation)
        h.service.enqueue(observation)
        h.service.enqueue(h.observation())
        await h.service.waitUntilIdle()
        XCTAssertEqual(h.client.messages.count, 1)
        XCTAssertTrue(h.client.messages[0].body.contains("5-hour quota"))
        XCTAssertTrue(h.client.messages[0].body.contains("Weekly quota"))
        let payload = try await h.store.load(initialized: true)
        XCTAssertEqual(payload.accounts[h.identity.key]?.windows.count, 2)
        XCTAssertEqual(Set(payload.accounts[h.identity.key]!.windows.values.compactMap { $0.submission?.id }).count, 1)
        h.makeService()
        h.service.enqueue(h.observation())
        await h.service.waitUntilIdle()
        XCTAssertEqual(h.client.messages.count, 1)
    }

    @MainActor func testSecondWindowLaterAlertsAndSteadyLowDoesNotWrite() async throws {
        let h = try AlertHarness()
        h.service.enqueue(h.observation(weekly: 80))
        await h.service.waitUntilIdle()
        XCTAssertEqual(h.client.messages.count, 1)
        h.service.enqueue(h.observation())
        await h.service.waitUntilIdle()
        XCTAssertEqual(h.client.messages.count, 2)
        XCTAssertFalse(h.client.messages[1].body.contains("5-hour quota"))
        let before = try Data(contentsOf: h.url)
        let reads = h.client.permissionReads
        h.date.addTimeInterval(120)
        h.service.enqueue(h.observation(fiveHour: 1, weekly: 1))
        await h.service.waitUntilIdle()
        XCTAssertEqual(try Data(contentsOf: h.url), before)
        XCTAssertEqual(h.client.permissionReads, reads)
    }

    @MainActor func testDeniedPermissionConsumesNoChanceAndNeedsNewObservation() async throws {
        let h = try AlertHarness()
        h.client.authorization = .denied
        h.service.enqueue(h.observation())
        await h.service.waitUntilIdle()
        XCTAssertTrue(h.client.messages.isEmpty)
        let payload = try await h.store.load(initialized: true)
        XCTAssertFalse(payload.accounts[h.identity.key]!.windows.values.contains(where: \.occupied))
        h.client.authorization = .allowed
        await h.service.refreshPermission()
        XCTAssertTrue(h.client.messages.isEmpty)
        h.service.enqueue(h.observation())
        await h.service.waitUntilIdle()
        XCTAssertEqual(h.client.messages.count, 1)
    }

    @MainActor func testPermissionReadFailureDoesNotUsePreviouslyAllowedState() async throws {
        let h = try AlertHarness()
        await h.service.refreshPermission()
        h.client.failPermissionRead = true
        h.service.enqueue(h.observation())
        await h.service.waitUntilIdle()
        XCTAssertTrue(h.client.messages.isEmpty)
        XCTAssertNil(h.service.permissionState)
        XCTAssertTrue(h.service.permissionReadFailed)
        h.client.failPermissionRead = false
        h.service.enqueue(h.observation())
        await h.service.waitUntilIdle()
        XCTAssertEqual(h.client.messages.count, 1)
    }

    @MainActor func testSameIdentityAcrossEntriesAndDistinctUsersRemainIndependent() async throws {
        let h = try AlertHarness()
        h.service.enqueue(h.observation(entry: "primary"))
        h.service.enqueue(h.observation(entry: "imported"))
        await h.service.waitUntilIdle()
        XCTAssertEqual(h.client.messages.count, 1)
        let other = QuotaAlertIdentity(accountID: "test-account", userID: "other-user")!
        h.identities.append(other)
        h.service.enqueue(h.observation(identity: other))
        await h.service.waitUntilIdle()
        XCTAssertEqual(h.client.messages.count, 2)
        let weak = QuotaAlertIdentity(accountID: "test-account", userID: nil)!
        h.service.enqueue(h.observation(identity: weak))
        await h.service.waitUntilIdle()
        XCTAssertEqual(h.client.messages.count, 2)
    }

    @MainActor func testUnlimitedMissingAndUnknownWindowsNeverBecomeZero() async throws {
        let h = try AlertHarness()
        let source = h.observation()
        for variant in 0...2 {
            var snapshot = source.raw
            if variant == 0 { snapshot.isUnlimited = true }
            if variant == 1 { snapshot.primaryLimit = nil; snapshot.secondaryLimit = nil }
            if variant == 2 { snapshot.primaryLimit?.kind = .unknown; snapshot.secondaryLimit?.kind = .modelWeekly }
            h.service.enqueue(QuotaAlertObservation(id: UUID(), identity: h.identity, entry: "entry", entryVersion: 0,
                                                    settingsVersion: 0, observedAt: h.date, raw: snapshot, display: snapshot))
        }
        await h.service.waitUntilIdle()
        XCTAssertTrue(h.client.messages.isEmpty)
        XCTAssertEqual(h.client.permissionReads, 0)
    }

    @MainActor func testInheritedDisplayResetIsNotNewCycleEvidence() async throws {
        let h = try AlertHarness()
        h.service.enqueue(h.observation())
        await h.service.waitUntilIdle()
        h.date.addTimeInterval(18_001)
        let next = h.observation()
        var raw = next.raw
        raw.primaryLimit?.window.resetsAt = nil
        h.service.enqueue(QuotaAlertObservation(id: UUID(), identity: h.identity, entry: "entry", entryVersion: 0,
                                               settingsVersion: 0, observedAt: h.date, raw: raw, display: next.display))
        await h.service.waitUntilIdle()
        XCTAssertEqual(h.client.messages.count, 1)
        let stored = try await h.store.load(initialized: true)
        XCTAssertEqual(stored.accounts[h.identity.key]!.windows["fiveHour"]!.anchor,
                       Date(timeIntervalSince1970: 1_790_000_000).addingTimeInterval(18_000))
    }

    @MainActor func testFailureCooldownAndRetryReuseIdentifier() async throws {
        let h = try AlertHarness()
        h.client.failSubmission = true
        h.service.enqueue(h.observation())
        await h.service.waitUntilIdle()
        let failedID = h.client.attempts[0]
        h.client.failSubmission = false
        h.date.addTimeInterval(599)
        h.service.enqueue(h.observation())
        await h.service.waitUntilIdle()
        XCTAssertEqual(h.client.attempts.count, 1)
        h.date.addTimeInterval(1)
        h.service.enqueue(h.observation())
        await h.service.waitUntilIdle()
        XCTAssertEqual(h.client.attempts, [failedID, failedID])
        XCTAssertEqual(h.client.messages.count, 1)
    }

    @MainActor func testStaleContextAndShutdownWhilePermissionReadPreventSending() async throws {
        let h = try AlertHarness()
        h.client.beforePermission = { h.current = false }
        h.service.enqueue(h.observation())
        await h.service.waitUntilIdle()
        XCTAssertTrue(h.client.messages.isEmpty)
        h.current = true
        h.client.beforePermission = { h.service.suspendForTermination() }
        h.service.enqueue(h.observation())
        await h.service.waitUntilIdle()
        XCTAssertTrue(h.client.messages.isEmpty)
    }

    @MainActor func testPreparedExistsBeforeSubmitAndSurvivesUncertainCrash() async throws {
        let h = try AlertHarness()
        h.client.beforeSubmit = {
            let payload = try! JSONDecoder().decode(QuotaAlertPayload.self, from: Data(contentsOf: h.url))
            XCTAssertTrue(payload.accounts[h.identity.key]!.windows.values.allSatisfy { $0.submission?.status == .prepared })
        }
        h.service.enqueue(h.observation())
        await h.service.waitUntilIdle()
        var payload = try await h.store.load(initialized: true)
        for kind in ["fiveHour", "weekly"] { payload.accounts[h.identity.key]?.windows[kind]?.submission?.status = .prepared }
        try await h.store.save(payload)
        h.makeService()
        h.service.enqueue(h.observation())
        await h.service.waitUntilIdle()
        XCTAssertEqual(h.client.messages.count, 1)
    }

    @MainActor func testBrokenMissingFutureSchemaAndExplicitRebuild() async throws {
        for contents in ["broken", "{\"version\":3}"] {
            let h = try AlertHarness()
            try Data(contents.utf8).write(to: h.url)
            h.service.enqueue(h.observation())
            await h.service.waitUntilIdle()
            XCTAssertTrue(h.service.storagePaused)
            XCTAssertTrue(h.client.messages.isEmpty)
            XCTAssertEqual(try String(contentsOf: h.url, encoding: .utf8), contents)
            await h.service.rebuild(entries: ["entry"])
            h.service.enqueue(h.observation())
            await h.service.waitUntilIdle()
            XCTAssertTrue(h.client.messages.isEmpty)
            let files = try FileManager.default.contentsOfDirectory(atPath: h.directory.path)
            XCTAssertTrue(files.contains { $0.hasPrefix("quota-alert-state-backup-") })
        }
        let h = try AlertHarness()
        h.initialized = true
        h.service.enqueue(h.observation())
        await h.service.waitUntilIdle()
        XCTAssertTrue(h.service.storagePaused)
        XCTAssertTrue(h.client.messages.isEmpty)
    }

    @MainActor func testPreparedWriteFailureNeverCallsSystem() async throws {
        let h = try AlertHarness(writer: { data, url in
            let payload = try JSONDecoder().decode(QuotaAlertPayload.self, from: data)
            if payload.accounts.values.contains(where: { $0.windows.values.contains(where: \.occupied) }) {
                throw CocoaError(.fileWriteNoPermission)
            }
            try data.write(to: url, options: .atomic)
        })
        h.service.enqueue(h.observation())
        await h.service.waitUntilIdle()
        XCTAssertTrue(h.service.storagePaused)
        XCTAssertTrue(h.client.attempts.isEmpty)
    }

    @MainActor func testExternalFileReplacementIsPreserved() async throws {
        let h = try AlertHarness()
        h.service.enqueue(h.observation(fiveHour: 80, weekly: 80))
        await h.service.waitUntilIdle()
        let corrupt = Data("external replacement".utf8)
        try corrupt.write(to: h.url, options: .atomic)
        h.service.enqueue(h.observation())
        await h.service.waitUntilIdle()
        XCTAssertTrue(h.service.storagePaused)
        XCTAssertTrue(h.client.messages.isEmpty)
        XCTAssertEqual(try Data(contentsOf: h.url), corrupt)
    }

    @MainActor func testAcceptedWriteFailureKeepsPreparedOnDisk() async throws {
        let h = try AlertHarness(writer: { data, url in
            let payload = try JSONDecoder().decode(QuotaAlertPayload.self, from: data)
            if payload.accounts.values.contains(where: { $0.windows.values.contains(where: { $0.submission?.status == .accepted }) }) {
                throw CocoaError(.fileWriteNoPermission)
            }
            try data.write(to: url, options: .atomic)
        })
        h.service.enqueue(h.observation())
        await h.service.waitUntilIdle()
        XCTAssertEqual(h.client.messages.count, 1)
        XCTAssertTrue(h.service.storagePaused)
        h.makeService()
        h.service.enqueue(h.observation())
        await h.service.waitUntilIdle()
        XCTAssertEqual(h.client.messages.count, 1)
    }

    @MainActor func testPermissionDeniedIsNotRepeatedlyRequested() async throws {
        let h = try AlertHarness()
        h.client.authorization = .notDetermined
        h.client.denyRequest = true
        await h.service.requestPermissionIfNeeded()
        await h.service.requestPermissionIfNeeded()
        XCTAssertEqual(h.client.authorizationRequests, 1)
        XCTAssertEqual(h.service.permissionState?.authorization, .denied)
    }

    @MainActor func testPrivacyCleanupDoesNotResetDedupe() async throws {
        let h = try AlertHarness()
        h.service.enqueue(h.observation())
        await h.service.waitUntilIdle()
        let before = try Data(contentsOf: h.url)
        h.service.settingsChanged(clearNotifications: true)
        h.service.enqueue(h.observation())
        await h.service.waitUntilIdle()
        // 清理任务由服务串行持有；后续新候选会等待完成。
        XCTAssertEqual(try Data(contentsOf: h.url), before)
        XCTAssertEqual(h.client.messages.count, 1)
        XCTAssertGreaterThan(h.client.removals, 0)
    }
}

@MainActor
private final class FakeAlertClient: QuotaNotificationClient {
    var authorization: QuotaNotificationPermission.Authorization = .allowed
    var denyRequest = false
    var failSubmission = false
    var failPermissionRead = false
    var permissionReads = 0
    var authorizationRequests = 0
    var removals = 0
    var attempts: [String] = []
    var messages: [QuotaNotificationMessage] = []
    var beforePermission: (() -> Void)?
    var beforeSubmit: (() -> Void)?

    func permission() async throws -> QuotaNotificationPermission {
        permissionReads += 1
        let hook = beforePermission
        beforePermission = nil
        hook?()
        if failPermissionRead { throw CocoaError(.coderReadCorrupt) }
        return QuotaNotificationPermission(authorization: authorization, alerts: authorization == .allowed, sound: true)
    }
    func requestAuthorization(sound: Bool) async throws {
        authorizationRequests += 1
        authorization = denyRequest ? .denied : .allowed
    }
    func submit(_ message: QuotaNotificationMessage) async throws {
        attempts.append(message.identifier)
        let hook = beforeSubmit
        beforeSubmit = nil
        hook?()
        if failSubmission { throw CocoaError(.coderInvalidValue) }
        messages.append(message)
    }
    func removeNotifications(accountKey: String?) async { removals += 1 }
}

@MainActor
private final class AlertHarness {
    var prefs: QuotaAlertPreferences
    var date = Date(timeIntervalSince1970: 1_790_000_000)
    var initialized = false
    var current = true
    let directory: URL
    let url: URL
    let store: QuotaAlertStore
    let client = FakeAlertClient()
    let identity = QuotaAlertIdentity(accountID: "test-account", userID: "test-user")!
    var identities: [QuotaAlertIdentity] = []
    var service: QuotaNotificationService!

    init(enabled: Bool = true, writer: @escaping QuotaAlertStore.Writer = { try $0.write(to: $1, options: .atomic) }) throws {
        prefs = QuotaAlertPreferences(enabled: enabled)
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("quota-alert-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        url = directory.appendingPathComponent("state.json")
        store = QuotaAlertStore(url: url, writer: writer)
        identities = [identity]
        makeService()
    }

    deinit { try? FileManager.default.removeItem(at: directory) }

    func makeService() {
        service = QuotaNotificationService(
            client: client, store: store, preferences: { [unowned self] in prefs },
            context: { [unowned self] _ in current ? QuotaAlertDisplayContext(name: "Test", privacyKey: "entry") : nil },
            activeIdentities: { [unowned self] in identities },
            initialized: { [unowned self] in initialized }, markInitialized: { [unowned self] in initialized = true },
            now: { [unowned self] in date }, loggingEnabled: false,
            translate: { english, _ in english }, displayAccount: { $0.name }, resetHint: { _, _ in "reset" }
        )
    }

    func observation(snapshot: QuotaSnapshot) -> QuotaAlertObservation {
        let identity = QuotaAlertIdentity(app: snapshot.app, accountID: "test-account", userID: "test-user")!
        if !identities.contains(identity) { identities.append(identity) }
        return QuotaAlertObservation(id: UUID(), identity: identity, entry: "primary:\(snapshot.app.rawValue)", entryVersion: 0,
                                     settingsVersion: 0, observedAt: snapshot.fetchedAt, raw: snapshot, display: snapshot)
    }

    func observation(fiveHour: Double = 5, weekly: Double = 5, at: Date? = nil,
                     identity: QuotaAlertIdentity? = nil, entry: String = "entry") -> QuotaAlertObservation {
        let time = at ?? date
        let snapshot = QuotaSnapshot(
            app: .codex,
            primaryLimit: .standard(kind: .fiveHour, window: QuotaWindow(
                usedPercent: 100 - fiveHour, resetsAt: time.addingTimeInterval(18_000), windowSeconds: 18_000
            )),
            secondaryLimit: .standard(kind: .weekly, window: QuotaWindow(
                usedPercent: 100 - weekly, resetsAt: time.addingTimeInterval(604_800), windowSeconds: 604_800
            )), planType: nil, fetchedAt: time
        )
        return QuotaAlertObservation(id: UUID(), identity: identity ?? self.identity, entry: entry, entryVersion: 0,
                                     settingsVersion: 0, observedAt: time, raw: snapshot, display: snapshot)
    }
}
