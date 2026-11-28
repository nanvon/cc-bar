import XCTest
@testable import CCBar

/// 不读真实钥匙串、不使用真实账号、不调用 agy。覆盖 Antigravity 只读凭据识别与 `agy -p "/usage"` 解析链路。
final class AntigravityCredentialsTests: XCTestCase {
    private var home: URL!

    override func setUpWithError() throws {
        home = FileManager.default.temporaryDirectory.appendingPathComponent("ccbar-ag-auth-\(UUID())")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws { try FileManager.default.removeItem(at: home) }

    private func keychain(_ json: String) -> AntigravityCredentials.CLITokenLoad {
        AntigravityCredentials.parseKeychainToken(Data(("go-keyring-base64:" + Data(json.utf8).base64EncodedString()).utf8))
    }

    private func write(_ path: String, _ text: String) throws {
        let url = home.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url)
    }

    func testGUIKeychainOnlyIsDetectedWithoutAnyLegacyFileOrCLI() throws {
        let loaded = keychain(#"{"auth_method":"oauth-personal","token":{"access_token":"gui","refresh_token":"refresh","expiry":"2099-01-01T00:00:00.123456789Z"}}"#)
        let account = try XCTUnwrap(AntigravityCredentials.load(homeDirectory: home, keychainLoader: { loaded }))
        XCTAssertEqual(account.source, .keychain)
        XCTAssertEqual(account.accessToken, "gui")
        XCTAssertEqual(account.refreshToken, "refresh")
        XCTAssertFalse(AntigravityCredentials.isExpired(expiryDate: account.expiryDate))
        XCTAssertNotNil(account.credentialSignature)
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: home.path).isEmpty)
    }

    func testCurrentGUIAccountWinsOverStaleLegacyFiles() throws {
        try write(".gemini/jetski-standalone-oauth-token", #"{"token":{"access_token":"old-user"}}"#)
        try write(".gemini/antigravity-cli/antigravity-oauth-token", #"{"access_token":"old-cli-user"}"#)
        let loaded = keychain(#"{"token":{"access_token":"current-gui-user"}}"#)
        let account = try AntigravityCredentials.load(homeDirectory: home, keychainLoader: { loaded })
        XCTAssertEqual(account?.accessToken, "current-gui-user")
    }

    func testDeniedOrMalformedKeychainDoesNotUseAnotherAccountsFile() throws {
        try write(".gemini/jetski-standalone-oauth-token", #"{"token":{"access_token":"old-user"}}"#)
        for loaded in [AntigravityCredentials.CLITokenLoad.unreadable(.transport("denied")), keychain("{}"), keychain("not json")] {
            XCTAssertThrowsError(try AntigravityCredentials.load(homeDirectory: home, keychainLoader: { loaded }))
        }
    }

    func testMissingKeychainRetainsLegacyCLITokenSupport() throws {
        try write(".gemini/antigravity-cli/antigravity-oauth-token", #"{"token":{"access_token":"cli","refresh_token":"r"}}"#)
        let account = try AntigravityCredentials.load(homeDirectory: home, keychainLoader: { .missing })
        XCTAssertEqual(account?.source, .cliToken)
        XCTAssertEqual(account?.accessToken, "cli")
    }

    func testRawCamelCaseKeychainAndRefreshOnlyCredentials() throws {
        let loaded = AntigravityCredentials.parseKeychainToken(Data(#"{"refreshToken":"r","expiresAt":1790000000000}"#.utf8))
        let account = try XCTUnwrap(AntigravityCredentials.load(homeDirectory: home, keychainLoader: { loaded }))
        XCTAssertNil(account.accessToken)
        XCTAssertEqual(account.refreshToken, "r")
        XCTAssertEqual(account.expiryDate?.timeIntervalSince1970, 1_790_000_000)
    }

    func testKeychainExtractsIdTokenEmailFallback() throws {
        let loaded = keychain(#"{"auth_method":"oauth-personal","id_token_email":"user@example.com","token":{"access_token":"gui","refresh_token":"refresh","expiry":"2099-01-01T00:00:00Z"}}"#)
        let account = try XCTUnwrap(AntigravityCredentials.load(homeDirectory: home, keychainLoader: { loaded }))
        XCTAssertEqual(account.email, "user@example.com")
    }

    func testLoadCLITokenReadsKeychainOnceAndFallsBackToLegacyFile() throws {
        var calls = 0
        let loaded = keychain(#"{"token":{"access_token":"valid","refresh_token":"r","expiry":"2099-01-01T00:00:00Z"}}"#)
        let result = AntigravityCredentials.loadCLIToken(homeDirectory: home) {
            calls += 1
            return loaded
        }
        XCTAssertEqual(calls, 1)
        guard case .found(let token) = result else { return XCTFail("expected found token") }
        XCTAssertTrue(token.isValid)

        try write(".gemini/antigravity-cli/antigravity-oauth-token", #"{"token":{"access_token":"legacy","expiry":"2000-01-01T00:00:00Z"}}"#)
        let fallback = AntigravityCredentials.loadCLIToken(homeDirectory: home) { .missing }
        guard case .found(let legacy) = fallback else { return XCTFail("expected fallback cli token") }
        XCTAssertEqual(legacy.source, .cliToken)
        XCTAssertFalse(legacy.isValid)
    }

    func testParseCLISupportsUsageAndQuotaCommandsAndArgonCarbonOrder() throws {
        for commandName in ["usage", "quota"] {
            let root: [String: Any] = [
                "status": "SUCCESS",
                "num_turns": 0,
                "command": [
                    "name": commandName,
                    "data": [
                        "groups": [
                            [
                                "name": "Gemini 4 Argon",
                                "buckets": [[
                                    "id": "gemini-argon-wtu-weekly",
                                    "name": "Gemini 4 Argon Weekly Limit",
                                    "window": "weekly",
                                    "remaining_fraction": 0.75,
                                    "reset_time": "2099-01-01T00:00:00Z",
                                ]],
                            ],
                            [
                                "name": "Gemini Models",
                                "buckets": [
                                    [
                                        "id": "gemini-weekly",
                                        "name": "Weekly Limit Remaining",
                                        "window": "weekly",
                                        "remaining_fraction": 0.85,
                                        "reset_time": "2099-01-01T00:00:00Z",
                                    ],
                                    [
                                        "id": "gemini-5h",
                                        "name": "Five Hour Limit Remaining",
                                        "window": "5h",
                                        "remaining_fraction": 0.9,
                                        "reset_time": "2099-01-01T00:00:00Z",
                                    ],
                                ],
                            ],
                            [
                                "name": "Claude and GPT models",
                                "buckets": [
                                    [
                                        "id": "3p-5h",
                                        "name": "Five Hour Limit Remaining",
                                        "window": "5h",
                                        "remaining_fraction": 0.6,
                                        "reset_time": "2099-01-01T00:00:00Z",
                                    ],
                                    [
                                        "id": "3p-weekly",
                                        "name": "Weekly Limit Remaining",
                                        "window": "weekly",
                                        "remaining_fraction": 0.7,
                                        "reset_time": "2099-01-01T00:00:00Z",
                                    ],
                                ],
                            ],
                        ],
                    ],
                ],
            ]
            let snapshot = try XCTUnwrap(AntigravityQuotaClient.parseCLI(root: root))
            XCTAssertEqual(snapshot.allLimits.map(\.id), [
                "gemini-5h", "gemini-weekly", "claude-5h", "claude-weekly", "gemini-argon-wtu-weekly",
            ])
            XCTAssertEqual(snapshot.primaryWindow?.remainingPercent ?? 0, 90, accuracy: 0.01)
            XCTAssertEqual(snapshot.auxiliaryLimits.last?.window.remainingPercent ?? 0, 75, accuracy: 0.01)
        }
    }

    func testEvaluateCLIRunHandlesRateLimitAuthAndIncompleteOutput() throws {
        let rateLimitData = try JSONSerialization.data(withJSONObject: [
            "status": "ERROR",
            "response": "HTTP 429 RESOURCE_EXHAUSTED",
        ])
        let rateLimited = AntigravityQuotaClient.evaluateCLIRun(.init(
            data: rateLimitData, errorData: nil, exitStatus: 1, timedOut: false, drained: true
        ))
        guard case .failure(let rateErr) = rateLimited, rateErr.isRateLimited else {
            return XCTFail("expected rate limit failure")
        }

        let authErr = AntigravityQuotaClient.evaluateCLIRun(.init(
            data: nil, errorData: Data("Not logged in. Please sign in again.".utf8), exitStatus: 1, timedOut: false, drained: true
        ))
        guard case .failure(.antigravitySignedOut) = authErr else {
            return XCTFail("expected antigravitySignedOut")
        }

        let truncated = AntigravityQuotaClient.evaluateCLIRun(.init(
            data: Data("{\"status\":\"SUCCESS\"".utf8), errorData: nil, exitStatus: 0, timedOut: true, drained: true
        ))
        guard case .failure(.transport) = truncated else {
            return XCTFail("expected transport error for truncated JSON")
        }
    }

    func testCLIExecutableDiscoveryChecksPathAndFallbackLocations() {
        let foundInHome = AntigravityQuotaClient.cliExecutable(
            environment: ["PATH": "/usr/bin:/bin"],
            homeDirectory: home,
            isExecutable: { $0 == home.appendingPathComponent(".local/bin/agy").path }
        )
        XCTAssertEqual(foundInHome, home.appendingPathComponent(".local/bin/agy"))

        let missing = AntigravityQuotaClient.cliExecutable(
            environment: ["PATH": "/usr/bin:/bin"],
            homeDirectory: home,
            isExecutable: { _ in false }
        )
        XCTAssertNil(missing)
    }

    func testUnbridgedNSURLErrorCannotConnectMapsToCannotConnect() {
        let rawError = NSError(domain: NSURLErrorDomain, code: NSURLErrorCannotConnectToHost)
        guard case .network(.cannotConnect) = QuotaError.from(transport: rawError) else {
            return XCTFail("expected .network(.cannotConnect)")
        }
    }
}
