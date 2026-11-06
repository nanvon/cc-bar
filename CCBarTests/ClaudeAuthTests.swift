import XCTest
@testable import CCBar

/// ziin：凭据样本仅用于解析测试，不读取钥匙串、账号文件或网络。
final class ClaudeAuthTests: XCTestCase {
    func testMCPOnlyCredentialsAreRejectedForBothSources() {
        let data = Data(#"{"mcpOAuth":{"test-server":{}}}"#.utf8)

        for source in [CredentialSource.file, .keychain] {
            XCTAssertThrowsError(try ClaudeAuth.parse(data: data, source: source)) { error in
                guard case CredentialError.decodeFailed(let message) = error else {
                    return XCTFail("预期缺少 Claude 登录令牌，实际错误：\(error)")
                }
                XCTAssertEqual(message, "missing Claude OAuth access token")
            }
        }
    }

    func testMissingEmptyAndInvalidAccessTokensAreRejected() {
        let samples = [
            #"{}"#,
            #"{"claudeAiOauth":{}}"#,
            #"{"claudeAiOauth":{"refreshToken":"test-refresh"}}"#,
            #"{"claudeAiOauth":{"accessToken":null}}"#,
            #"{"claudeAiOauth":{"accessToken":123}}"#,
            #"{"claudeAiOauth":{"accessToken":""}}"#,
            #"{"claudeAiOauth":{"accessToken":" \t\n"}}"#,
            #"{"claudeAiOauth":{"access_token":""}}"#,
            #"{"claudeAiOauth":{"access_token":" \t\n"}}"#,
        ]

        for sample in samples {
            XCTAssertThrowsError(
                try ClaudeAuth.parse(data: Data(sample.utf8), source: .keychain),
                "缺少非空登录令牌的凭据必须被拒绝：\(sample)"
            )
        }
    }

    func testValidOAuthCredentialsPreserveAccountFieldsAlongsideMCPData() throws {
        let data = Data(#"{"mcpOAuth":{},"claudeAiOauth":{"accessToken":"test-access","refreshToken":"test-refresh","emailAddress":"test@example.com","subscriptionType":"pro","expiresAt":4102444800000}}"#.utf8)
        let account = try ClaudeAuth.parse(data: data, source: .keychain)
        let expirationSeconds: TimeInterval = 4_102_444_800

        XCTAssertEqual(account.source, .keychain)
        XCTAssertEqual(account.accessToken, "test-access")
        XCTAssertEqual(account.refreshToken, "test-refresh")
        XCTAssertEqual(account.email, "test@example.com")
        XCTAssertEqual(account.subscriptionType, "pro")
        XCTAssertEqual(account.expiresAt, Date(timeIntervalSince1970: expirationSeconds))
        XCTAssertFalse(account.expiredGuess)
    }

    func testSnakeCaseAccessTokenRemainsSupported() throws {
        let data = Data(#"{"claudeAiOauth":{"access_token":"test-access","refresh_token":"test-refresh"}}"#.utf8)
        let account = try ClaudeAuth.parse(data: data, source: .file)

        XCTAssertEqual(account.source, .file)
        XCTAssertEqual(account.accessToken, "test-access")
        XCTAssertEqual(account.refreshToken, "test-refresh")
    }

    func testMalformedJSONAndNonObjectCredentialsRemainErrors() {
        for sample in ["not json", "[]"] {
            XCTAssertThrowsError(
                try ClaudeAuth.parse(data: Data(sample.utf8), source: .file)
            )
        }
    }
}
