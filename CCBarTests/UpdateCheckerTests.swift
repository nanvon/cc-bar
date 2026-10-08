import XCTest
import Sparkle
@testable import CCBar

final class UpdateCheckerTests: XCTestCase {
    // MARK: - 完整更新授权与跨版本日志

    @MainActor
    func testReadyUpdateRequiresConsentAndThenRelaunchesWithoutSecondConfirmation() {
        let updater = AppUpdater()
        var firstChoice: SPUUserUpdateChoice?
        updater.showReady(toInstallAndRelaunch: { firstChoice = $0 })
        XCTAssertNil(firstChoice, "恢复的包没有用户授权时不得自动安装")
        XCTAssertTrue(updater.canInstall)

        updater.installUpdate()
        XCTAssertEqual(firstChoice, .install)
        var readyChoice: SPUUserUpdateChoice?
        updater.showReady(toInstallAndRelaunch: { readyChoice = $0 })
        XCTAssertEqual(readyChoice, .install, "首次已授权后，下载准备完成直接安装重启")
    }

    @MainActor
    func testDismissedSessionDoesNotReusePreviousInstallationConsent() {
        let updater = AppUpdater()
        updater.showReady(toInstallAndRelaunch: { _ in })
        updater.installUpdate()
        updater.dismissUpdateInstallation()
        var choice: SPUUserUpdateChoice?
        updater.showReady(toInstallAndRelaunch: { choice = $0 })
        XCTAssertNil(choice)
        XCTAssertTrue(updater.canInstall)
    }

    func testReleaseNotesIncludeEverySkippedVersionAndHideInstalledVersions() {
        let notes = "## 1.2.0\n\n**新增**\n- newest\n\n## v1.1.9\n- skipped\n\n## 1.1.8\n- installed\n"
        let changes = UpdateReleaseNotes.changes(in: notes, since: "1.1.8")
        XCTAssertTrue(changes.contains("newest"))
        XCTAssertTrue(changes.contains("skipped"))
        XCTAssertFalse(changes.contains("installed"))
        XCTAssertFalse(changes.contains("## 1.1.8"))
    }

    func testSingleVersionNotesPreserveSectionHeadings() {
        let notes = "**注意**\n- keep this\n\n## 修复\n- fixed"
        XCTAssertEqual(UpdateReleaseNotes.changes(in: notes, since: "1.1.4"), notes)
    }

    // MARK: - numericComponents

    func testNumericComponentsVariantForms() {
        XCTAssertEqual(UpdateChecker.numericComponents(of: "v1.0.2"), [1, 0, 2])
        XCTAssertEqual(UpdateChecker.numericComponents(of: "1.0.2"), [1, 0, 2])
        XCTAssertEqual(UpdateChecker.numericComponents(of: "1.0"), [1, 0])
        XCTAssertEqual(UpdateChecker.numericComponents(of: "V2.3.4"), [2, 3, 4])
    }

    func testNumericComponentsSuffixTruncated() {
        XCTAssertEqual(UpdateChecker.numericComponents(of: "1.0.2-beta.1"), [1, 0, 2])
    }

    func testNumericComponentsInvalid() {
        XCTAssertNil(UpdateChecker.numericComponents(of: ""))
        XCTAssertNil(UpdateChecker.numericComponents(of: "abc"))
        XCTAssertNil(UpdateChecker.numericComponents(of: "v.1.0"))
    }

    // MARK: - isNewer

    func testNewerVersion() {
        XCTAssertTrue(UpdateChecker.isNewer(tag: "v1.0.2", than: "1.0.1"))
        XCTAssertTrue(UpdateChecker.isNewer(tag: "v1.1.0", than: "1.0.9"))
        XCTAssertTrue(UpdateChecker.isNewer(tag: "v2.0.0", than: "1.9.9"))
    }

    func testSameOrOlderVersionNotNewer() {
        XCTAssertFalse(UpdateChecker.isNewer(tag: "v1.0.1", than: "1.0.1"))
        XCTAssertFalse(UpdateChecker.isNewer(tag: "v1.0.0", than: "1.0.1"))
        XCTAssertFalse(UpdateChecker.isNewer(tag: "v0.9.9", than: "1.0.0"))
        XCTAssertFalse(UpdateChecker.isNewer(tag: "v1.0", than: "1.0.0"))
    }

    func testIsNewerMalformedTagTreatsAsNotNewer() {
        XCTAssertFalse(UpdateChecker.isNewer(tag: "invalid", than: "1.0.1"))
        XCTAssertFalse(UpdateChecker.isNewer(tag: "", than: "1.0.1"))
    }

    // MARK: - isRateLimited

    private func response(status: Int, headers: [String: String] = [:]) -> HTTPURLResponse {
        HTTPURLResponse(
            url: UpdateChecker.latestReleaseAPIURL,
            statusCode: status,
            httpVersion: "HTTP/1.1",
            headerFields: headers
        )!
    }

    func testRateLimitedWhenQuotaExhausted() {
        XCTAssertTrue(UpdateChecker.isRateLimited(response(status: 403, headers: ["x-ratelimit-remaining": "0"])))
        XCTAssertTrue(UpdateChecker.isRateLimited(response(status: 429)))
    }

    func testNotRateLimitedForOtherFailures() {
        // 403 但仍有余额:属于权限/其他问题,不能报成限流。
        XCTAssertFalse(UpdateChecker.isRateLimited(response(status: 403, headers: ["x-ratelimit-remaining": "42"])))
        XCTAssertFalse(UpdateChecker.isRateLimited(response(status: 403)))
        XCTAssertFalse(UpdateChecker.isRateLimited(response(status: 404)))
        XCTAssertFalse(UpdateChecker.isRateLimited(response(status: 500)))
    }
}
