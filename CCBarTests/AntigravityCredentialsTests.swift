import XCTest
@testable import CCBar

/// 不读真实钥匙串、不使用真实账号、不调用 agy。覆盖 issue #13 的 GUI-only 登录与续期链路。
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

    func testGUIRefreshNeverCreatesOrOverwritesLegacyCredentialFiles() throws {
        let path = ".gemini/jetski-standalone-oauth-token"
        try write(path, "original")
        let account = AntigravityAccount(accessToken: "old", refreshToken: "r", credentialSignature: "gui-login", source: .keychain)
        var cacheKeys: [String] = []
        try AntigravityCredentials.persistRefreshedToken(
            .init(accessToken: "new", refreshToken: "rotated", expiryDate: .distantFuture),
            account: account, homeDirectory: home,
            cacheWriter: { token, key in
                XCTAssertEqual(token.accessToken, "new")
                cacheKeys.append(key)
            }
        )
        XCTAssertEqual(cacheKeys, [account.refreshKey])
        XCTAssertEqual(try String(contentsOf: home.appendingPathComponent(path), encoding: .utf8), "original")
        XCTAssertFalse(FileManager.default.fileExists(atPath: home.appendingPathComponent(".gemini/oauth_creds.json").path))
    }

    func testDesktopOAuthDiscoveryIncludesGUIBinaryAndKeepsSeparatedSecrets() throws {
        let applications = home.appendingPathComponent("Applications")
        let paths = AntigravityCredentials.desktopOAuthArtifacts(homeDirectory: home, applicationRoots: [applications])
        let binary = try XCTUnwrap(paths.first { $0.path.hasSuffix("Contents/Resources/bin/language_server") })
        let first = "GOCSPX-" + String(repeating: "a", count: 28)
        let second = "GOCSPX-" + String(repeating: "b", count: 28)
        // Go 字符串池的 ID/secret 相隔很远，后面还有粘连文本；无 CLI 文件。
        try FileManager.default.createDirectory(at: binary.deletingLastPathComponent(), withIntermediateDirectories: true)
        var data = Data([0xff, 0x00])
        data.append(Data((AntigravityCredentials.antigravityClientID + String(repeating: "-", count: 1024) + first + second + "httpsTrailing").utf8))
        try data.write(to: binary)
        XCTAssertEqual(Set(AntigravityCredentials.clientSecrets(inBinary: binary).values), [first, second])
    }

    func testExpiredGUIGrantRefreshesWithoutCLIAndFormEncodesCredentials() async throws {
        let harness = AntigravityRefreshHarness(refresh: "r+&=% value")
        var account = harness.account
        account.accessToken = nil
        let token = try await AntigravityCredentials.ensureFreshAccessToken(account: &account, environment: harness.environment).get()
        XCTAssertEqual(token, "fresh-access")
        XCTAssertEqual(account.source, .keychain)
        XCTAssertEqual(harness.requestBodies.count, 1)
        XCTAssertTrue(harness.requestBodies[0].contains("refresh_token=r%2B%26%3D%25%20value"))
        XCTAssertEqual(harness.savedKeys, [harness.account.refreshKey])
    }

    func testRestartUsesOwnCacheOnlyWhileGUIOriginalLoginStillMatches() async throws {
        let harness = AntigravityRefreshHarness()
        harness.setCached(.init(accessToken: "cached", refreshToken: "rotated", expiryDate: .distantFuture))
        var account = harness.account
        let cached = try await AntigravityCredentials.ensureFreshAccessToken(account: &account, environment: harness.environment).get()
        XCTAssertEqual(cached, "cached")
        XCTAssertTrue(harness.requestBodies.isEmpty)
        let oldAccount = harness.account
        harness.replaceLogin()
        var stale = oldAccount
        let staleResult = await AntigravityCredentials.ensureFreshAccessToken(account: &stale, environment: harness.environment)
        if case .success = staleResult { XCTFail("切号后不允许借用旧缓存") }
        XCTAssertTrue(harness.requestBodies.isEmpty)
    }

    func testAccountSwitchWhileRefreshingDoesNotSaveOrAdoptOldToken() async throws {
        let harness = AntigravityRefreshHarness()
        harness.switchOnSend = true
        var account = harness.account
        let result = await AntigravityCredentials.ensureFreshAccessToken(account: &account, environment: harness.environment)
        if case .success = result { XCTFail("切号期间的旧结果应丢弃") }
        XCTAssertTrue(harness.savedKeys.isEmpty)
        XCTAssertNotEqual(account.refreshKey, harness.account.refreshKey)
    }

    func testOAuth429StopsWithoutTryingOtherClientCandidates() async {
        let harness = AntigravityRefreshHarness()
        harness.status = 429
        var account = harness.account
        let result = await AntigravityCredentials.ensureFreshAccessToken(account: &account, environment: harness.environment)
        guard case .failure(let error) = result else { return XCTFail("expected 429") }
        XCTAssertTrue(error.isRateLimited)
        XCTAssertEqual(harness.requestBodies.count, 1)
    }

    func testSameLoginRefreshesCoalesceAndDifferentLoginsStaySeparate() async throws {
        let first = AntigravityRefreshHarness()
        let second = AntigravityRefreshHarness()
        let tokens = await withTaskGroup(of: String?.self, returning: [String?].self) { group in
            for harness in [first, first, second] {
                group.addTask {
                    var account = harness.account
                    return try? await AntigravityCredentials.ensureFreshAccessToken(account: &account, environment: harness.environment).get()
                }
            }
            var result: [String?] = []
            for await token in group { result.append(token) }
            return result
        }
        XCTAssertEqual(tokens.compactMap { $0 }.count, 3)
        XCTAssertEqual(first.requestBodies.count, 1)
        XCTAssertEqual(second.requestBodies.count, 1)
        XCTAssertNotEqual(first.savedKeys, second.savedKeys)
    }
}

final class AntigravityDesktopQuotaTests: XCTestCase {
    private func setup() -> [String: Any] {
        ["currentTier": ["id": "free-tier"], "paidTier": ["id": "g1-pro-tier", "name": "Google AI Pro"],
         "cloudaicompanionProject": "account-project"]
    }

    private func groups(_ ids: [String], remaining: Double = 0.75) -> [String: Any] {
        ["groups": ids.map { id in
            ["displayName": id, "buckets": [["bucketId": id, "remainingFraction": remaining,
                                             "window": id.contains("weekly") ? "weekly" : "5h",
                                             "resetTime": "2099-01-01T00:00:00Z"]]] as [String: Any]
        }]
    }

    private var allIDs: [String] { ["gemini-argon-wtu-weekly", "gemini-5h", "gemini-weekly", "3p-5h", "3p-weekly"] }

    nonisolated private func response(_ request: URLRequest, _ root: [String: Any], status: Int = 200) throws -> (Data, URLResponse) {
        (try JSONSerialization.data(withJSONObject: root),
         HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!)
    }

    func testGUICloudQueryCarriesRealProjectAndDesktopMetadataAndReturnsAllFiveLimits() async throws {
        let setup = setup(), groups = groups(allIDs)
        let result = await AntigravityQuotaClient.fetch(accessToken: "gui-access") { request in
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer gui-access")
            XCTAssertTrue(request.value(forHTTPHeaderField: "User-Agent")?.contains("aidev_client") == true)
            let body = try XCTUnwrap(JSONSerialization.jsonObject(with: request.httpBody!) as? [String: Any])
            if request.url!.absoluteString.contains("loadCodeAssist") {
                XCTAssertEqual((body["metadata"] as? [String: String])?["ideType"], "ANTIGRAVITY")
                return try self.response(request, setup)
            }
            XCTAssertTrue(request.url!.absoluteString.contains("retrieveUserQuotaSummary"))
            XCTAssertEqual(body["project"] as? String, "account-project")
            return try self.response(request, groups)
        }
        let fetched = try result.get()
        XCTAssertEqual(fetched.snapshot.allLimits.count, 5)
        XCTAssertEqual(fetched.snapshot.primaryLimit?.id, "gemini-argon-wtu-weekly")
        XCTAssertEqual(fetched.snapshot.primaryWindow?.remainingPercent, 75)
        XCTAssertEqual(fetched.snapshot.planType, "Google AI Pro")
    }

    func testPartialDailyGroupsAreCompletedWithoutOverwritingAlreadyMeasuredBuckets() async throws {
        let setup = setup(), partial = groups(["3p-5h", "3p-weekly"], remaining: 0.8), complete = groups(allIDs, remaining: 0.2)
        let result = await AntigravityQuotaClient.fetch(accessToken: "gui") { request in
            if request.url!.absoluteString.contains("loadCodeAssist") { return try self.response(request, setup) }
            XCTAssertTrue(request.url!.absoluteString.contains("retrieveUserQuotaSummary"), "有分组额度后不请求另一种模型池")
            return try self.response(request, request.url!.host!.hasPrefix("daily-") ? partial : complete)
        }
        let snapshot = try result.get().snapshot
        XCTAssertEqual(snapshot.allLimits.count, 5)
        XCTAssertEqual(snapshot.allLimits.first { $0.id == "claude-5h" }?.window.remainingPercent, 80)
        XCTAssertEqual(snapshot.primaryWindow?.remainingPercent, 20)
    }

    func testWeeklyOnlyGUIAccountDoesNotInventFiveHourLimits() async throws {
        let setup = setup(), weekly = groups(["gemini-weekly", "3p-weekly"])
        let result = await AntigravityQuotaClient.fetch(accessToken: "gui") { request in
            try self.response(request, request.url!.absoluteString.contains("loadCodeAssist") ? setup : ["response": weekly])
        }
        XCTAssertEqual(try result.get().snapshot.allLimits.map(\.kind), [.weekly, .weekly])
    }

    func testSummary429And401DoNotContinueWithFallbackEndpoints() async {
        for status in [429, 401] {
            let setup = setup()
            let result = await AntigravityQuotaClient.fetch(accessToken: "gui") { request in
                XCTAssertEqual(request.url!.host, "daily-cloudcode-pa.googleapis.com")
                if request.url!.absoluteString.contains("loadCodeAssist") { return try self.response(request, setup) }
                XCTAssertTrue(request.url!.absoluteString.contains("retrieveUserQuotaSummary"))
                return try self.response(request, ["error": "rejected"], status: status)
            }
            guard case .failure(let error) = result else { XCTFail("expected failure"); continue }
            XCTAssertEqual(error.httpStatusCode, status)
        }
    }

    func testUnverifiedFullModelListDoesNotBecomeSuccessful100PercentQuota() async {
        let setup = setup()
        let result = await AntigravityQuotaClient.fetch(accessToken: "gui") { request in
            let url = request.url!.absoluteString
            if url.contains("loadCodeAssist") { return try self.response(request, setup) }
            if url.contains("fetchAvailableModels") {
                return try self.response(request, ["models": ["gemini-3.1-pro": ["quotaInfo": ["remainingFraction": 1.0]]]])
            }
            return try self.response(request, ["error": "permission denied"], status: 403)
        }
        if case .success = result { XCTFail("模型可用性不能冒充真实额度") }
    }

    func testUnsupportedOAuthClientDoesNotQueryPlaceholderSummary() async {
        let result = await AntigravityQuotaClient.fetch(accessToken: "gui") { request in
            XCTAssertTrue(request.url!.absoluteString.contains("loadCodeAssist"))
            return try self.response(request, ["ineligibleTiers": [["reasonCode": "GOOGLE_TOS_NOT_SUPPORTED_BY_CLIENT"]]])
        }
        guard case .failure(let error) = result else { return XCTFail("expected failure") }
        XCTAssertEqual(error.httpStatusCode, 403)
    }

    func testProjectSupportsObjectShapeAndRejectsBlank() {
        XCTAssertEqual(AntigravityQuotaClient.projectID(in: ["cloudaicompanionProject": ["id": "p"]]), "p")
        XCTAssertNil(AntigravityQuotaClient.projectID(in: ["cloudaicompanionProject": "  "]))
    }
}

nonisolated private final class AntigravityRefreshHarness: @unchecked Sendable {
    private let lock = NSLock()
    private var login: AntigravityAccount
    private var cached: AntigravityCredentials.RefreshedToken?
    private var bodies: [String] = []
    private var keys: [String] = []
    var status = 200
    var switchOnSend = false

    init(refresh: String = "refresh") {
        login = AntigravityAccount(accessToken: "expired", refreshToken: refresh, expiryDate: .distantPast,
                                   credentialSignature: UUID().uuidString, source: .keychain)
    }

    var account: AntigravityAccount { lock.lock(); defer { lock.unlock() }; return login }
    var requestBodies: [String] { lock.lock(); defer { lock.unlock() }; return bodies }
    var savedKeys: [String] { lock.lock(); defer { lock.unlock() }; return keys }
    func setCached(_ token: AntigravityCredentials.RefreshedToken) { lock.lock(); defer { lock.unlock() }; cached = token }
    func replaceLogin() { lock.lock(); defer { lock.unlock() }; login.credentialSignature = UUID().uuidString; login.refreshToken = UUID().uuidString }

    private func record(_ request: URLRequest) -> Int {
        lock.lock(); defer { lock.unlock() }
        bodies.append(String(data: request.httpBody ?? Data(), encoding: .utf8) ?? "")
        return status
    }

    var environment: AntigravityCredentials.RefreshEnvironment {
        .init(
            load: { self.account },
            secrets: { [AntigravityCredentials.antigravityClientID: "GOCSPX-" + String(repeating: "a", count: 28)] },
            send: { request in
                let status = self.record(request)
                try await Task.sleep(nanoseconds: 20_000_000)
                if self.switchOnSend { self.replaceLogin() }
                let json = status == 200 ? #"{"access_token":"fresh-access","refresh_token":"rotated","expires_in":3600}"# : #"{"error":"rate_limit"}"#
                return (Data(json.utf8), HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!)
            },
            cached: { _ in self.lock.lock(); defer { self.lock.unlock() }; return self.cached },
            save: { token, account in
                self.lock.lock(); defer { self.lock.unlock() }
                self.cached = token
                self.keys.append(account.refreshKey)
            }
        )
    }
}
