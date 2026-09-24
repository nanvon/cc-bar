import XCTest
@testable import CCBar

/// DSH 诊断的脱敏保证测试。
///
/// 依据：`docs/草案-DSH本地用量-技术方案.md` §1、§5（诊断只记录默认根存在性、候选文件数量与
/// 扫描结果，不记录会话路径、标题、正文或凭据）。
final class DshDiagnosticsTests: XCTestCase {
    private var logs: DshTempLogRoot!

    override func setUpWithError() throws {
        logs = try DshTempLogRoot(name: "dsh-diagnostics-test")
    }

    override func tearDownWithError() throws {
        logs = nil
    }

    func testMissingRootReportsMissing() {
        let missing = logs.root.appendingPathComponent("not-created", isDirectory: true)
        XCTAssertEqual(DiagnosticsBundle.describeDshSource(missing), "missing")
    }

    func testCandidateCountUsesCanonicalNamesAndLeaksNoPathOrName() throws {
        try logs.write(project: "项目段", session: "会话段", file: "session.jsonl.zstd", bytes: Data([1]))
        try logs.write(project: "项目段", session: "会话段", file: "session.v3.jsonl.zstd", bytes: Data([1]))
        // 非规范名：锁文件、大写、v0 都不计入候选
        try logs.write(project: "项目段", session: "会话段", file: "session.v3.jsonl.zstd.lock", bytes: Data([1]))
        try logs.write(project: "项目段", session: "会话段", file: "session.V9.jsonl.zstd", bytes: Data([1]))
        try logs.write(project: "项目段", session: "会话段", file: "session.v0.jsonl.zstd", bytes: Data([1]))

        let described = DiagnosticsBundle.describeDshSource(logs.root)
        XCTAssertTrue(described.hasPrefix("present candidate-logs=2 "), "实际：\(described)")
        XCTAssertTrue(described.contains("newest="))
        // 脱敏：输出里不得出现任何目录段名、文件名或绝对路径
        XCTAssertFalse(described.contains("项目段"))
        XCTAssertFalse(described.contains("会话段"))
        XCTAssertFalse(described.contains("session"))
        XCTAssertFalse(described.contains(logs.root.path))
    }
}
