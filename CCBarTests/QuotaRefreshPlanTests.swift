import XCTest
@testable import CCBar

/// 草案 §4.1 的 Provider 开关组合矩阵：计划构造与镜像判定。
final class QuotaRefreshPlanTests: XCTestCase {
    // MARK: - Plan 组合矩阵（纯函数）

    func testAllProvidersEnabled() {
        let plan = QuotaRefreshPlan.make(
            showCodex: true,
            showClaude: true,
            showCursor: true,
            showCommandCode: true,
            hasVisibleImported: true
        )
        XCTAssertTrue(plan.refreshCodex)
        XCTAssertTrue(plan.refreshClaude)
        XCTAssertTrue(plan.refreshCursor)
        XCTAssertTrue(plan.refreshCommandCode)
        XCTAssertTrue(plan.refreshImported)
        XCTAssertTrue(plan.canMirrorPrimary)
    }

    func testAllProvidersDisabled() {
        let plan = QuotaRefreshPlan.make(
            showCodex: false,
            showClaude: false,
            showCursor: false,
            showCommandCode: false,
            hasVisibleImported: false
        )
        XCTAssertFalse(plan.refreshCodex)
        XCTAssertFalse(plan.refreshClaude)
        XCTAssertFalse(plan.refreshCursor)
        XCTAssertFalse(plan.refreshCommandCode)
        XCTAssertFalse(plan.refreshImported)
        XCTAssertFalse(plan.canMirrorPrimary)
    }

    func testCodexOnly() {
        let plan = QuotaRefreshPlan.make(
            showCodex: true, showClaude: false, showCursor: false, hasVisibleImported: false
        )
        XCTAssertTrue(plan.refreshCodex)
        XCTAssertFalse(plan.refreshClaude)
        XCTAssertFalse(plan.refreshCursor)
        XCTAssertTrue(plan.canMirrorPrimary)
    }

    func testClaudeOnly() {
        let plan = QuotaRefreshPlan.make(
            showCodex: false, showClaude: true, showCursor: false, hasVisibleImported: false
        )
        XCTAssertFalse(plan.refreshCodex)
        XCTAssertTrue(plan.refreshClaude)
        XCTAssertFalse(plan.refreshCursor)
        XCTAssertFalse(plan.canMirrorPrimary)
    }

    func testCodexPlusClaude() {
        let plan = QuotaRefreshPlan.make(
            showCodex: true, showClaude: true, showCursor: false, hasVisibleImported: false
        )
        XCTAssertTrue(plan.refreshCodex)
        XCTAssertTrue(plan.refreshClaude)
        XCTAssertFalse(plan.refreshCursor)
        XCTAssertTrue(plan.canMirrorPrimary)
    }

    /// hasVisibleImported 只影响导入调度标志，不影响主 Provider 与镜像能力。
    func testVisibleImportedIndependentFromProviders() {
        let plan = QuotaRefreshPlan.make(
            showCodex: false, showClaude: false, showCursor: false, hasVisibleImported: true
        )
        XCTAssertFalse(plan.refreshCodex)
        XCTAssertFalse(plan.canMirrorPrimary)
        XCTAssertTrue(plan.refreshImported)
    }

    func testCursorOnly() {
        let plan = QuotaRefreshPlan.make(
            showCodex: false,
            showClaude: false,
            showCursor: true,
            hasVisibleImported: false
        )

        XCTAssertFalse(plan.refreshCodex)
        XCTAssertFalse(plan.refreshClaude)
        XCTAssertTrue(plan.refreshCursor)
        XCTAssertFalse(plan.refreshImported)
        XCTAssertFalse(plan.canMirrorPrimary)
    }

    func testCursorDisplayDefaultsStayDisabledUntilItsUIIsReleased() {
        let defaults = ProviderDisplaySettings.defaults(for: .cursor)

        XCTAssertFalse(defaults.enabled)
        XCTAssertFalse(defaults.menuBar)
        XCTAssertFalse(defaults.floatingHUD)
    }

    func testCommandCodeOnly() {
        let plan = QuotaRefreshPlan.make(
            showCodex: false,
            showClaude: false,
            showCursor: false,
            showCommandCode: true,
            hasVisibleImported: false
        )

        XCTAssertFalse(plan.refreshCodex)
        XCTAssertFalse(plan.refreshClaude)
        XCTAssertFalse(plan.refreshCursor)
        XCTAssertTrue(plan.refreshCommandCode)
        XCTAssertFalse(plan.refreshImported)
        XCTAssertFalse(plan.canMirrorPrimary)
    }

    func testCommandCodeDisplayDefaultsStayDisabled() {
        let defaults = ProviderDisplaySettings.defaults(for: .commandCode)

        XCTAssertFalse(defaults.enabled)
        XCTAssertTrue(defaults.menuBar)
        XCTAssertTrue(defaults.floatingHUD)
    }

    // MARK: - 镜像判定矩阵（AppState 展示层）

    private var appState: AppState!
    private var savedShowCodex: Bool!

    override func setUp() {
        super.setUp()
        savedShowCodex = SettingsStore.shared.showCodex
        appState = AppState()
    }

    override func tearDown() {
        SettingsStore.shared.showCodex = savedShowCodex
        appState = nil
        super.tearDown()
    }

    private func makeAccount(id: String) -> ImportedCodexAccount {
        ImportedCodexAccount(
            id: id,
            alias: "",
            email: nil,
            planType: nil,
            visibleInPopover: true,
            addedAt: Date()
        )
    }

    private func makePrimary(accountId: String, userId: String?) -> CodexAccount {
        CodexAccount(
            email: nil,
            planType: nil,
            accountId: accountId,
            chatgptUserId: userId,
            lastRefresh: nil,
            expiredGuess: false,
            rawClaimKeys: [],
            accessToken: nil,
            refreshToken: nil,
            idToken: nil
        )
    }

    @MainActor
    func testMirrorPrimaryOnSameIdentity() {
        appState.codexAccount = makePrimary(accountId: "acc-1", userId: "user-1")
        let imported = makeAccount(id: "acc-1:user-1")
        SettingsStore.shared.showCodex = true
        XCTAssertTrue(appState.importedCodexAccountMirrorsPrimary(imported))
    }

    /// 主 Codex 关闭时，即使内存还留有旧身份，导入账号也不能镜像旧快照（草案 2.1）。
    @MainActor
    func testMirrorDisabledWhenPrimaryProviderOff() {
        appState.codexAccount = makePrimary(accountId: "acc-1", userId: "user-1")
        let imported = makeAccount(id: "acc-1:user-1")
        SettingsStore.shared.showCodex = false
        XCTAssertFalse(appState.importedCodexAccountMirrorsPrimary(imported))
    }

    @MainActor
    func testNoMirrorOnDifferentIdentity() {
        appState.codexAccount = makePrimary(accountId: "acc-1", userId: "user-1")
        let imported = makeAccount(id: "acc-2:user-2")
        SettingsStore.shared.showCodex = true
        XCTAssertFalse(appState.importedCodexAccountMirrorsPrimary(imported))
    }

    @MainActor
    func testNoMirrorWhenPrimaryMissing() {
        appState.codexAccount = nil
        let imported = makeAccount(id: "acc-1:user-1")
        SettingsStore.shared.showCodex = true
        XCTAssertFalse(appState.importedCodexAccountMirrorsPrimary(imported))
    }

    /// 老数据：导入账号无 user_id（单段 id），主账号有 user_id → 退化为 accountId 相同即镜像。
    @MainActor
    func testMirrorDegradesToAccountIdWhenImportedUserIdMissing() {
        appState.codexAccount = makePrimary(accountId: "acc-1", userId: "user-1")
        let imported = makeAccount(id: "acc-1")
        SettingsStore.shared.showCodex = true
        XCTAssertTrue(appState.importedCodexAccountMirrorsPrimary(imported))
    }
}

/// 「是否开始刷新」的纯函数与各服务差异表（改进建议 2026-11 第 3 条）。
final class QuotaRefreshGateTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func decide(
        _ state: QuotaRefreshState,
        reason: QuotaRefreshReason = .periodic,
        interval: TimeInterval = QuotaRefreshPolicy.defaultMinSuccessInterval
    ) -> QuotaRefreshGate.Decision {
        QuotaRefreshGate.decide(state: state, reason: reason, now: now, minSuccessInterval: interval)
    }

    func testStartsWithFreshState() {
        XCTAssertEqual(decide(QuotaRefreshState()), .start)
    }

    func testSkipsWhileInFlight() {
        var state = QuotaRefreshState()
        state.inFlight = true
        XCTAssertEqual(decide(state), .skip)
        XCTAssertEqual(decide(state, reason: .userInitiated), .skip)
    }

    func testBackoffBlocksPeriodicAndManualRefresh() {
        var state = QuotaRefreshState()
        let until = now.addingTimeInterval(300)
        state.backoffUntil = until
        XCTAssertEqual(decide(state), .backingOff(until: until))
        XCTAssertEqual(decide(state, reason: .userInitiated), .backingOff(until: until))
    }

    func testExpiredBackoffAllowsRefresh() {
        var state = QuotaRefreshState()
        state.backoffUntil = now.addingTimeInterval(-1)
        XCTAssertEqual(decide(state), .start)
    }

    func testInFlightTakesPrecedenceOverBackoff() {
        var state = QuotaRefreshState()
        state.inFlight = true
        state.backoffUntil = now.addingTimeInterval(300)
        XCTAssertEqual(decide(state), .skip)
    }

    func testMinSuccessIntervalOnlyLimitsPeriodicRefresh() {
        var state = QuotaRefreshState()
        state.lastSuccessAt = now.addingTimeInterval(-30)
        XCTAssertEqual(decide(state), .skip)
        XCTAssertEqual(decide(state, reason: .userInitiated), .start)
    }

    func testPeriodicRefreshStartsAfterMinSuccessInterval() {
        var state = QuotaRefreshState()
        state.lastSuccessAt = now.addingTimeInterval(-60)
        XCTAssertEqual(decide(state), .start)
    }

    func testAntigravityUsesLongerMinSuccessInterval() {
        XCTAssertEqual(QuotaRefreshPolicy.minSuccessInterval(for: .antigravity), 120)
        for app in QuotaApp.allCases where app != .antigravity {
            XCTAssertEqual(QuotaRefreshPolicy.minSuccessInterval(for: app), 60, "\(app)")
        }
        var state = QuotaRefreshState()
        state.lastSuccessAt = now.addingTimeInterval(-90)
        XCTAssertEqual(decide(state, interval: QuotaRefreshPolicy.minSuccessInterval(for: .antigravity)), .skip)
        XCTAssertEqual(decide(state, interval: QuotaRefreshPolicy.minSuccessInterval(for: .codex)), .start)
    }

    func testClaudeKeepsBackoffAfterCLIFallbackSuccess() {
        XCTAssertTrue(QuotaRefreshPolicy.clearsBackoffOnSuccess(.claude, source: .api))
        XCTAssertFalse(QuotaRefreshPolicy.clearsBackoffOnSuccess(.claude, source: .cliFallback))
        for app in QuotaApp.allCases where app != .claude {
            XCTAssertTrue(QuotaRefreshPolicy.clearsBackoffOnSuccess(app, source: .api), "\(app)")
            XCTAssertTrue(QuotaRefreshPolicy.clearsBackoffOnSuccess(app, source: .antigravityCLI), "\(app)")
        }
    }
}
