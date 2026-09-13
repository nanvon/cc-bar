import XCTest
@testable import CCBar

/// 脱敏是这套诊断日志的核心约束：日志会被用户导出发给开发者，漏一次就是泄露一次。
/// 见 `docs/草案-诊断日志-设计方案.md` §4 与 §9。
final class RedactTests: XCTestCase {
    // MARK: - 兜底清洗

    func testScrubRemovesJWT() {
        let token = "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJzdWIiOiIxMjM0NTY3ODkwIn0.dBjftJeZ4CVPmB92K27uhbUJU1p1r_wW1gFWFOEjXk"
        let output = Redact.scrub("authorization header carried \(token) for the request")
        XCTAssertFalse(output.contains("eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9"))
        XCTAssertFalse(output.contains("dBjftJeZ4CVPmB92K27uhbUJU1p1r_wW1gFWFOEjXk"))
    }

    func testScrubRemovesAPIKeys() {
        let anthropic = "sk-ant-api03-AbCdEfGhIjKlMnOpQrStUvWxYz0123456789"
        let openai = "sk-proj-AbCdEfGhIjKlMnOpQrStUvWxYz0123456789"
        let personal = "at-9f8e7d6c5b4a3210fedcba98"
        let output = Redact.scrub("keys: \(anthropic) \(openai) \(personal)")
        for secret in [anthropic, openai, personal] {
            XCTAssertFalse(output.contains(secret), "leaked \(secret)")
            XCTAssertFalse(output.contains(String(secret.suffix(12))), "leaked tail of \(secret)")
        }
    }

    func testScrubRemovesBearerAndKeyValueForms() {
        let output = Redact.scrub(#"Authorization: Bearer abc123def456ghi789 refresh_token="rt_secret_value""#)
        XCTAssertFalse(output.contains("abc123def456ghi789"))
        XCTAssertFalse(output.contains("rt_secret_value"))
    }

    func testScrubRemovesEmailAndUUIDAndHomePath() {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let input = "user nanvon.hsu@gmail.com uuid 3F2504E0-4F89-11D3-9A0C-0305E82C3301 at \(home)/.claude"
        let output = Redact.scrub(input)
        XCTAssertFalse(output.contains("nanvon.hsu@gmail.com"))
        XCTAssertFalse(output.contains("3F2504E0-4F89-11D3-9A0C-0305E82C3301"))
        XCTAssertFalse(output.contains(home))
        XCTAssertTrue(output.contains("~/.claude"))
    }

    func testScrubRemovesLongOpaqueBlobs() {
        let blob = String(repeating: "A1b2C3d4", count: 8) // 64 字符
        let output = Redact.scrub("payload=\(blob)")
        XCTAssertFalse(output.contains(blob))
    }

    func testScrubStripsURLQuery() {
        let output = Redact.scrub("GET https://api.example.com/v1/usage?account_id=abc&token=zzz")
        XCTAssertFalse(output.contains("account_id=abc"))
        XCTAssertFalse(output.contains("token=zzz"))
        XCTAssertTrue(output.contains("https://api.example.com/v1/usage"))
    }

    /// 清洗必须保留正常诊断字段，否则日志就没法定位问题了。
    func testScrubKeepsOrdinaryDiagnosticFields() {
        let line = "codex source=remote plan=plus primary[fiveHour]=87.0% left hasAccess=true hasRefresh=false"
        XCTAssertEqual(Redact.scrub(line), line)
    }

    // MARK: - 账号哈希

    func testAccountHashIsStableAndOpaque() {
        let email = "nanvon.hsu@gmail.com"
        let first = Redact.account(email)
        XCTAssertEqual(first, Redact.account(email))
        XCTAssertTrue(first.hasPrefix("acct#"))
        XCTAssertFalse(first.contains("nanvon"))
        XCTAssertFalse(first.contains("gmail"))
        // 原文任意 4 字符连续子串都不应出现在哈希里
        let characters = Array(email)
        for start in 0...(characters.count - 4) {
            let fragment = String(characters[start..<(start + 4)])
            XCTAssertFalse(first.contains(fragment), "hash leaked fragment \(fragment)")
        }
    }

    func testAccountHashDiffersPerInput() {
        XCTAssertNotEqual(Redact.account("a@example.com"), Redact.account("b@example.com"))
        XCTAssertEqual(Redact.account(nil), "none")
        XCTAssertEqual(Redact.account(""), "none")
    }

    // MARK: - 路径与 URL

    func testPathHashesProjectNameAndKeepsShape() {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let output = Redact.path("\(home)/.claude/projects/acme-internal-repo/session.jsonl")
        XCTAssertTrue(output.hasPrefix("~/.claude/projects/proj#"))
        XCTAssertFalse(output.contains("acme-internal-repo"))
        XCTAssertTrue(output.hasSuffix("/file.jsonl"))
    }

    func testURLDropsQueryFragmentAndCredentials() {
        let url = URL(string: "https://user:pass@api.example.com/v1/me?token=secret#frag")!
        let output = Redact.url(url)
        XCTAssertFalse(output.contains("secret"))
        XCTAssertFalse(output.contains("pass"))
        XCTAssertFalse(output.contains("frag"))
        XCTAssertTrue(output.contains("api.example.com/v1/me"))
    }

    // MARK: - 错误

    /// `NSError.userInfo` 常带失败请求的完整 URL 与响应体，绝不能进日志。
    func testErrorDoesNotLeakUserInfo() {
        let error = NSError(
            domain: NSURLErrorDomain,
            code: -1009,
            userInfo: [
                NSLocalizedDescriptionKey: "offline",
                "failingToken": "sk-ant-api03-AbCdEfGhIjKlMnOpQrStUvWxYz0123456789",
            ]
        )
        let output = Redact.error(error)
        XCTAssertFalse(output.contains("sk-ant-api03"))
        XCTAssertFalse(output.contains("failingToken"))
        XCTAssertTrue(output.contains(NSURLErrorDomain))
        XCTAssertTrue(output.contains("-1009"))
    }

    func testMessageFlattensAndTruncates() {
        XCTAssertEqual(Redact.message(nil), "none")
        XCTAssertEqual(Redact.message("a\nb"), "a b")
        let long = String(repeating: "x", count: 500)
        XCTAssertLessThanOrEqual(Redact.message(long).count, 300)
    }
}
