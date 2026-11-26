import XCTest
@testable import CCBar

final class CommandCodeQuotaTests: XCTestCase {
    func testQuotaAppCapabilities() {
        XCTAssertNil(QuotaApp.commandCode.usageApp, "Command Code 不作为本地用量统计 app")

        let desc = QuotaProviderDescriptor.descriptor(for: .commandCode)
        XCTAssertNotNil(desc)
        XCTAssertTrue(desc?.supportsMenuBar == true, "Command Code 支持菜单栏")
        XCTAssertTrue(desc?.supportsFloatingHUD == true, "Command Code 支持悬浮窗")

        XCTAssertTrue(QuotaProviderDescriptor.accountProviders.contains(where: { $0.app == .commandCode }))
        XCTAssertTrue(QuotaProviderDescriptor.popoverProviders.contains(where: { $0.app == .commandCode }))
        XCTAssertTrue(QuotaProviderDescriptor.menuBarProviders.contains(where: { $0.app == .commandCode }))
        XCTAssertTrue(QuotaProviderDescriptor.floatingProviders.contains(where: { $0.app == .commandCode }))
    }

    func testTokenSanitization() {
        XCTAssertEqual(
            CommandCodeAuth.sanitizeToken("  cc_live_abc123\n\r\t "),
            "cc_live_abc123"
        )
        XCTAssertNil(CommandCodeAuth.sanitizeToken("short"))
        XCTAssertNil(CommandCodeAuth.sanitizeToken(""))
    }

    func testLocalAuthFileParsingWithOAuthAccess() throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        // 模拟 ~/.pi/agent/auth.json
        let piDir = tempDir.appendingPathComponent(".pi/agent")
        try FileManager.default.createDirectory(at: piDir, withIntermediateDirectories: true)
        let piJSON = """
        {
          "commandcode": {
            "type": "oauth",
            "access": "cc_live_pi_access_token_12345",
            "refresh": "cc_live_refresh_token_12345",
            "expires": 1788260759
          }
        }
        """.data(using: .utf8)!
        try piJSON.write(to: piDir.appendingPathComponent("auth.json"))

        let session = CommandCodeAuth.load(homeDirectory: tempDir, preference: .automatic)
        XCTAssertNotNil(session)
        XCTAssertEqual(session?.source, .pi)
        XCTAssertEqual(session?.accessToken, "cc_live_pi_access_token_12345")
    }

    func testRealEnvironmentDetection() throws {
        guard let session = CommandCodeAuth.load(preference: .automatic) else {
            throw XCTSkip("当前环境未检测到 Command Code 凭据，跳过本机环境检测")
        }
        XCTAssertTrue(session.source == .pi || session.source == .opencode || session.source == .commandCodeCLI || session.source == .environment)
    }

    func testWhoamiParsing() throws {
        let json = """
        {
          "user": {
            "id": "u_123456",
            "name": "Test User",
            "email": "user@example.com",
            "userName": "testuser"
          },
          "org": null
        }
        """.data(using: .utf8)!

        let whoami = try JSONDecoder().decode(CommandCodeQuotaClient.WhoamiResponse.self, from: json)
        XCTAssertEqual(whoami.user?.userName, "testuser")
        XCTAssertEqual(whoami.user?.name, "Test User")
        XCTAssertEqual(whoami.user?.email, "user@example.com")
        XCTAssertNil(whoami.org)
    }

    func testCreditsAndSubscriptionParsing() throws {
        let creditsJSON = """
        {
          "fiveHour": {
            "cap": 14.0,
            "used": 0.398,
            "resetAt": 1788260759193
          },
          "weekly": {
            "cap": 35.0,
            "used": 7.604,
            "resetAt": 1788865559193
          },
          "monthlyCredits": 62.395
        }
        """.data(using: .utf8)!

        let subJSON = """
        {
          "id": "sub_123",
          "planId": "individual-goat",
          "status": "active",
          "currentPeriodEnd": "2026-09-30T11:46:03.000Z"
        }
        """.data(using: .utf8)!

        let decoder = JSONDecoder()
        let credits = try decoder.decode(CommandCodeQuotaClient.CreditsResponse.self, from: creditsJSON)
        let sub = try decoder.decode(CommandCodeQuotaClient.SubscriptionResponse.self, from: subJSON)

        XCTAssertEqual(credits.fiveHour?.cap, 14.0)
        XCTAssertEqual(credits.fiveHour?.used, 0.398)
        XCTAssertEqual(credits.weekly?.cap, 35.0)
        XCTAssertEqual(credits.weekly?.used, 7.604)
        XCTAssertEqual(credits.monthlyCredits, 62.395)
        XCTAssertEqual(sub.planId, "individual-goat")

        // 毫秒时间戳转换校验
        let date = credits.fiveHour?.resetDate
        XCTAssertNotNil(date)
        XCTAssertEqual(date?.timeIntervalSince1970 ?? 0, 1788260759.193, accuracy: 0.001)
    }

    func testClientParseFlatStructure() throws {
        let flatCredits: [String: Any] = [
            "fiveHour": [
                "cap": 14.0,
                "used": 0.398,
                "resetAt": 1788260759193.0
            ] as [String: Any],
            "weekly": [
                "cap": 35.0,
                "used": 7.604,
                "resetAt": 1788865559193.0
            ] as [String: Any],
            "monthlyCredits": 62.395
        ]
        let subDict: [String: Any] = [
            "data": [
                "planId": "individual-goat",
                "currentPeriodEnd": "2026-09-30T11:46:03.000Z"
            ] as [String: Any]
        ]

        let (snapshot, plan) = CommandCodeQuotaClient.parse(
            creditsRoot: flatCredits,
            subscriptionsRoot: subDict
        )

        XCTAssertEqual(plan, "GOAT")
        XCTAssertNotNil(snapshot.primaryLimit)
        XCTAssertNotNil(snapshot.primaryWindow)
        XCTAssertEqual(snapshot.primaryLimit?.displayName, "5HOUR")
        XCTAssertEqual(snapshot.secondaryLimit?.displayName, "WEEKLY")
        XCTAssertEqual(snapshot.auxiliaryLimits.first?.displayName, "MONTHLY")

        let window = snapshot.primaryWindow!
        XCTAssertEqual(window.usedPercent, (0.398 / 14.0) * 100, accuracy: 0.01)
        XCTAssertGreaterThan(window.remainingPercent, 90.0)
    }

    func testClientParseNestedStructure() throws {
        let nestedCredits: [String: Any] = [
            "windowLimits": [
                "fiveHour": [
                    "cap": 14.0,
                    "used": 2.0,
                    "resetAt": 1788260759.0
                ] as [String: Any],
                "weekly": [
                    "cap": 35.0,
                    "used": 10.0,
                    "resetAt": 1788865559.0
                ] as [String: Any]
            ] as [String: Any],
            "credits": [
                "monthlyCredits": 50.0
            ] as [String: Any]
        ]
        let subDict: [String: Any] = [
            "data": [
                "planId": "individual-goat",
                "currentPeriodEnd": "2026-09-30T11:46:03.000Z"
            ] as [String: Any]
        ]

        let (snapshot, plan) = CommandCodeQuotaClient.parse(
            creditsRoot: nestedCredits,
            subscriptionsRoot: subDict
        )

        XCTAssertEqual(plan, "GOAT")
        XCTAssertNotNil(snapshot.primaryLimit)
        XCTAssertNotNil(snapshot.primaryWindow)
        XCTAssertEqual(snapshot.primaryWindow!.usedPercent, (2.0 / 14.0) * 100, accuracy: 0.01)
        XCTAssertNotNil(snapshot.secondaryLimit)
        XCTAssertEqual(snapshot.auxiliaryLimits.first?.displayName, "MONTHLY")
    }

    func testClientParseUnstartedCycleLeavesResetTimeNil() throws {
        let now = Date(timeIntervalSince1970: 1_750_000_000)
        let unstartedCredits: [String: Any] = [
            "fiveHour": [
                "cap": 14.0,
                "used": 0.0,
                "resetAt": 0
            ] as [String: Any],
            "weekly": [
                "cap": 35.0,
                "used": 0.0,
                "resetAt": 0
            ] as [String: Any]
        ]

        let (snapshot, _) = CommandCodeQuotaClient.parse(
            creditsRoot: unstartedCredits,
            subscriptionsRoot: nil,
            fetchedAt: now
        )

        let window = snapshot.primaryWindow
        XCTAssertNotNil(window)
        XCTAssertEqual(window?.usedPercent, 0)
        // 未开始周期不本地捏造重置时间，保留 nil 以便 UI 统一显示「尚未使用」。
        XCTAssertNil(window?.resetsAt)
        XCTAssertNil(snapshot.secondaryLimit?.window.resetsAt)
    }
}

