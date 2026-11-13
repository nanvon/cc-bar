import CoreServices
import XCTest
@testable import CCBar

/// 草案 §8.1 增量矩阵的补齐：deleted 文件 watermark 清理、archive/sessions
/// 同 ID 去重（mtime 取最新）、Claude minimumMtime 过滤。
final class ScannerIncrementalTests: XCTestCase {
    private var tempDir: URL!

    override func setUpWithError() throws {
        tempDir = Self.canonicalTempDirectory("scanner-inc")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let tempDir {
            try? FileManager.default.removeItem(at: tempDir)
        }
    }

    /// enumerator 返回的 URL 是 realpath 形式（/var → /private/var），
    /// 测试目录统一规范化，避免路径前缀差异导致 watermark key 匹配失败。
    private static func canonicalTempDirectory(_ name: String) -> URL {
        let raw = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(name)-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: raw, withIntermediateDirectories: true)
        return raw.path.withCString { cpath in
            guard let resolved = realpath(cpath, nil) else { return raw }
            defer { free(resolved) }
            return URL(fileURLWithPath: String(cString: resolved), isDirectory: true)
        }
    }

    private func copyFixture(named name: String, to destination: URL) throws -> URL {
        let source = try XCTUnwrap(
            Bundle(for: ScannerIncrementalTests.self).url(forResource: name, withExtension: "jsonl")
        )
        try FileManager.default.copyItem(at: source, to: destination)
        return destination
    }

    private func setMtime(_ date: Date, of url: URL) throws {
        try FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: url.path)
    }

    // MARK: - Codex

    /// 文件被删除后，下一轮扫描必须清理对应 watermark（alive 判定基于全量 key 集合）。
    func testCodexDeletedFileClearsWatermark() async throws {
        let sessions = tempDir.appendingPathComponent("sessions", isDirectory: true)
        let archived = tempDir.appendingPathComponent("archived", isDirectory: true)
        try FileManager.default.createDirectory(at: sessions, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: archived, withIntermediateDirectories: true)
        let id = "11111111-1111-4111-8111-111111111111"
        let file = try copyFixture(
            named: "codex-fast-scan",
            to: sessions.appendingPathComponent("rollout-2026-07-16T00-00-00-\(id).jsonl")
        )

        let first = await CodexJSONLScanner.scan(previous: [:], roots: [sessions, archived], indexedTitles: [:])
        XCTAssertEqual(first.entries.count, 3)
        XCTAssertNotNil(first.newState[id])

        try FileManager.default.removeItem(at: file)
        let second = await CodexJSONLScanner.scan(previous: first.newState, roots: [sessions, archived], indexedTitles: [:])
        XCTAssertNil(second.newState[id], "已删除会话的 watermark 应被清理")
    }

    /// sessions 与 archived_sessions 出现同 ID 会话时只取 mtime 最新的一个。
    func testCodexArchiveDedupPrefersNewestMtime() async throws {
        let sessions = tempDir.appendingPathComponent("sessions", isDirectory: true)
        let archived = tempDir.appendingPathComponent("archived", isDirectory: true)
        try FileManager.default.createDirectory(at: sessions, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: archived, withIntermediateDirectories: true)
        let id = "22222222-2222-4222-8222-222222222222"
        let old = try copyFixture(
            named: "codex-fast-scan",
            to: sessions.appendingPathComponent("rollout-2026-07-16T00-00-00-\(id).jsonl")
        )
        let newer = try copyFixture(
            named: "codex-fast-scan",
            to: archived.appendingPathComponent("rollout-2026-07-16T00-00-00-\(id).jsonl")
        )
        // archived 文件追加一条 token_count（4 条），并让 mtime 更新。
        let handle = try FileHandle(forWritingTo: newer)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data("""
        {"timestamp":"2026-07-16T00:00:12Z","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":600,"cached_input_tokens":120,"output_tokens":90,"reasoning_output_tokens":12,"total_tokens":690},"last_token_usage":{"input_tokens":200,"cached_input_tokens":40,"output_tokens":35,"reasoning_output_tokens":4,"total_tokens":235}}}}

        """.utf8))
        try handle.close()
        try setMtime(Date(timeIntervalSince1970: 1_000), of: old)
        try setMtime(Date(timeIntervalSince1970: 2_000), of: newer)

        let result = await CodexJSONLScanner.scan(previous: [:], roots: [sessions, archived], indexedTitles: [:])
        XCTAssertEqual(result.filesScanned, 1, "同 ID 会话只应解析最新的一份")
        XCTAssertEqual(result.entries.count, 4, "应解析 mtime 更新的 archived 文件（含追加行）")
    }

    /// 反向：mtime 更旧的一方胜出时同样只解析一份。
    func testCodexArchiveDedupPrefersNewestMtimeReversed() async throws {
        let sessions = tempDir.appendingPathComponent("sessions", isDirectory: true)
        let archived = tempDir.appendingPathComponent("archived", isDirectory: true)
        try FileManager.default.createDirectory(at: sessions, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: archived, withIntermediateDirectories: true)
        let id = "33333333-3333-4333-8333-333333333333"
        let old = try copyFixture(
            named: "codex-fast-scan",
            to: archived.appendingPathComponent("rollout-2026-07-16T00-00-00-\(id).jsonl")
        )
        let newer = try copyFixture(
            named: "codex-fast-scan",
            to: sessions.appendingPathComponent("rollout-2026-07-16T00-00-00-\(id).jsonl")
        )
        let handle = try FileHandle(forWritingTo: newer)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data("""
        {"timestamp":"2026-07-16T00:00:12Z","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":600,"cached_input_tokens":120,"output_tokens":90,"reasoning_output_tokens":12,"total_tokens":690},"last_token_usage":{"input_tokens":200,"cached_input_tokens":40,"output_tokens":35,"reasoning_output_tokens":4,"total_tokens":235}}}}

        """.utf8))
        try handle.close()
        try setMtime(Date(timeIntervalSince1970: 1_000), of: old)
        try setMtime(Date(timeIntervalSince1970: 2_000), of: newer)

        let result = await CodexJSONLScanner.scan(previous: [:], roots: [sessions, archived], indexedTitles: [:])
        XCTAssertEqual(result.filesScanned, 1)
        XCTAssertEqual(result.entries.count, 4, "mtime 新的 sessions 文件应胜出")
    }

    /// 受限重建按 mtime 过滤两个根目录：平铺归档和旧日期目录中续用的会话都不能漏扫。
    func testCodexMinimumMtimeIncludesFlatArchiveAndResumedOldSession() async throws {
        let sessions = tempDir.appendingPathComponent("sessions", isDirectory: true)
        let oldDatedSessions = sessions.appendingPathComponent("2020/01/01", isDirectory: true)
        let archived = tempDir.appendingPathComponent("archived_sessions", isDirectory: true)
        try FileManager.default.createDirectory(at: oldDatedSessions, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: archived, withIntermediateDirectories: true)
        let resumedID = "44444444-4444-4444-8444-444444444444"
        let archivedID = "55555555-5555-4555-8555-555555555555"
        let staleID = "66666666-6666-4666-8666-666666666666"
        let resumed = try copyFixture(
            named: "codex-fast-scan",
            to: oldDatedSessions.appendingPathComponent("rollout-2020-01-01T00-00-00-\(resumedID).jsonl")
        )
        let flatArchive = try copyFixture(
            named: "codex-fast-scan",
            to: archived.appendingPathComponent("rollout-2026-08-17T00-00-00-\(archivedID).jsonl")
        )
        let stale = try copyFixture(
            named: "codex-fast-scan",
            to: sessions.appendingPathComponent("rollout-2026-08-01T00-00-00-\(staleID).jsonl")
        )
        try setMtime(Date(timeIntervalSince1970: 2_000), of: resumed)
        try setMtime(Date(timeIntervalSince1970: 2_100), of: flatArchive)
        try setMtime(Date(timeIntervalSince1970: 1_000), of: stale)

        let result = await CodexJSONLScanner.scan(
            previous: [:],
            roots: [sessions, archived],
            indexedTitles: [:],
            minimumMtime: Date(timeIntervalSince1970: 1_500)
        )

        XCTAssertEqual(result.filesScanned, 2)
        XCTAssertNotNil(result.newState[resumedID], "旧日期目录中近期续用的会话应被扫描")
        XCTAssertNotNil(result.newState[archivedID], "平铺 archived_sessions 文件应被扫描")
        XCTAssertNil(result.newState[staleID])
    }

    func testCodexReportsUnreadableJSONLWithoutAdvancingItsWatermark() async throws {
        let sessions = tempDir.appendingPathComponent("sessions", isDirectory: true)
        let archived = tempDir.appendingPathComponent("archived", isDirectory: true)
        try FileManager.default.createDirectory(at: sessions, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: archived, withIntermediateDirectories: true)
        let id = "77777777-7777-4777-8777-777777777777"
        let file = try copyFixture(
            named: "codex-fast-scan",
            to: sessions.appendingPathComponent("rollout-2026-08-19T00-00-00-\(id).jsonl")
        )
        try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: file.path)
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        }

        let result = await CodexJSONLScanner.scan(
            previous: [:],
            roots: [sessions, archived],
            indexedTitles: [:]
        )

        XCTAssertEqual(result.failedFileCount, 1)
        XCTAssertEqual(result.newState[id]?.offset, 0, "读失败文件必须保留可重试的 watermark")
    }

    func testMissingRootsAreEmptyWhileInvalidRootsAreFailures() async throws {
        let missingClaude = tempDir.appendingPathComponent("missing-claude", isDirectory: true)
        let claude = ClaudeJSONLScanner.scan(
            previous: [:],
            seenMessageIds: [],
            root: missingClaude,
            conversationIndex: ConversationTitleIndex.ClaudeIndex(titles: [:], projects: [:])
        )
        let codex = await CodexJSONLScanner.scan(
            previous: [:],
            roots: [
                tempDir.appendingPathComponent("missing-codex-sessions", isDirectory: true),
                tempDir.appendingPathComponent("missing-codex-archive", isDirectory: true),
            ],
            indexedTitles: [:]
        )

        XCTAssertEqual(claude.failedFileCount, 0)
        XCTAssertEqual(codex.failedFileCount, 0)
        XCTAssertTrue(claude.entries.isEmpty)
        XCTAssertTrue(codex.entries.isEmpty)

        let notDirectory = tempDir.appendingPathComponent("not-a-directory")
        try Data().write(to: notDirectory)
        let invalidClaude = ClaudeJSONLScanner.scan(
            previous: [:],
            seenMessageIds: [],
            root: notDirectory,
            conversationIndex: ConversationTitleIndex.ClaudeIndex(titles: [:], projects: [:])
        )
        let invalidCodex = await CodexJSONLScanner.scan(
            previous: [:],
            roots: [notDirectory],
            indexedTitles: [:]
        )

        XCTAssertEqual(invalidClaude.failedFileCount, 1)
        XCTAssertEqual(invalidCodex.failedFileCount, 1)
    }

    func testJSONLReadOutcomeTreatsEnumeratedThenRemovedFileAsMissing() throws {
        let root = tempDir.appendingPathComponent("enumeration-race", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let file = root.appendingPathComponent("session.jsonl")
        try Data("{}\n".utf8).write(to: file)
        let descriptor = try XCTUnwrap(JSONLDirectoryEnumerator.enumerate(at: root).files.first)

        try FileManager.default.removeItem(at: file)

        guard case .missing = JSONLLineReader.readOutcome(url: descriptor.url, fromOffset: 0) else {
            return XCTFail("枚举后被移动或删除的文件应视为正常消失，不是读取失败")
        }
    }

    // MARK: - Codex 压缩日志（.jsonl.zst）

    private func codexFixtureData() throws -> Data {
        let source = try XCTUnwrap(
            Bundle(for: ScannerIncrementalTests.self).url(forResource: "codex-fast-scan", withExtension: "jsonl")
        )
        return try Data(contentsOf: source)
    }

    private func makeCodexRoots() throws -> (sessions: URL, archived: URL) {
        let sessions = tempDir.appendingPathComponent("sessions", isDirectory: true)
        let archived = tempDir.appendingPathComponent("archived", isDirectory: true)
        try FileManager.default.createDirectory(at: sessions, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: archived, withIntermediateDirectories: true)
        return (sessions, archived)
    }

    /// 模拟 Codex 的压缩：写出同名 `.jsonl.zst`、保留原 mtime、删掉明文。
    private func compressInPlace(_ plain: URL, streaming: Bool = false) throws -> URL {
        let data = try Data(contentsOf: plain)
        let mtime = try XCTUnwrap(
            FileManager.default.attributesOfItem(atPath: plain.path)[.modificationDate] as? Date
        )
        let compressed = URL(fileURLWithPath: plain.path + ".zst")
        let frame = streaming ? try DshTestFixtures.streamingFrame(data) : try DshTestFixtures.frame(data)
        try frame.write(to: compressed)
        try setMtime(mtime, of: compressed)
        try FileManager.default.removeItem(at: plain)
        return compressed
    }

    func testCodexReadsCompressedRollout() async throws {
        let (sessions, archived) = try makeCodexRoots()
        let id = "aaaaaaa1-1111-4111-8111-111111111111"
        let compressed = sessions.appendingPathComponent("rollout-2026-07-16T00-00-00-\(id).jsonl.zst")
        try DshTestFixtures.frame(try codexFixtureData()).write(to: compressed)

        let result = await CodexJSONLScanner.scan(previous: [:], roots: [sessions, archived], indexedTitles: [:])
        XCTAssertEqual(result.entries.count, 3)
        XCTAssertEqual(result.newState[id]?.offset, UInt64(try codexFixtureData().count), "offset 按解压后的字节计")
        XCTAssertEqual(result.conversationSeeds.first?.sourcePath, compressed.path)

        let second = await CodexJSONLScanner.scan(previous: result.newState, roots: [sessions, archived], indexedTitles: [:])
        XCTAssertTrue(second.entries.isEmpty)
        XCTAssertEqual(second.linesParsed, 0, "未变化的压缩日志不应再次解压解析")
    }

    /// 已扫完的明文被 Codex 压缩：沿用原 watermark，不重复计入。
    func testCodexCompressionAfterScanDoesNotRecount() async throws {
        for streaming in [false, true] {
            let (sessions, archived) = try makeCodexRoots()
            let id = streaming ? "aaaaaaa2-2222-4222-8222-222222222222" : "aaaaaaa3-3333-4333-8333-333333333333"
            let plain = try copyFixture(
                named: "codex-fast-scan",
                to: sessions.appendingPathComponent("rollout-2026-07-16T00-00-00-\(id).jsonl")
            )
            let first = await CodexJSONLScanner.scan(previous: [:], roots: [sessions, archived], indexedTitles: [:])
            XCTAssertEqual(first.entries.count, 3)

            _ = try compressInPlace(plain, streaming: streaming)
            let second = await CodexJSONLScanner.scan(previous: first.newState, roots: [sessions, archived], indexedTitles: [:])
            XCTAssertTrue(second.entries.isEmpty, "压缩前已入账的用量不能重复计入（帧头无 content size: \(streaming)）")
            XCTAssertEqual(second.newState[id]?.offset, first.newState[id]?.offset)
            XCTAssertNotNil(second.newState[id]?.fileSize)
            try FileManager.default.removeItem(at: sessions)
            try FileManager.default.removeItem(at: archived)
        }
    }

    /// resume 时 Codex 把压缩日志解压回明文再追加：只计入追加的部分。
    func testCodexMaterializedRolloutOnlyCountsAppendedUsage() async throws {
        let (sessions, archived) = try makeCodexRoots()
        let id = "aaaaaaa4-4444-4444-8444-444444444444"
        let plainURL = sessions.appendingPathComponent("rollout-2026-07-16T00-00-00-\(id).jsonl")
        let compressed = URL(fileURLWithPath: plainURL.path + ".zst")
        try DshTestFixtures.frame(try codexFixtureData()).write(to: compressed)
        try setMtime(Date(timeIntervalSince1970: 1_000), of: compressed)
        let first = await CodexJSONLScanner.scan(previous: [:], roots: [sessions, archived], indexedTitles: [:])
        XCTAssertEqual(first.entries.count, 3)

        var materialized = try codexFixtureData()
        materialized.append(Data("""
        {"timestamp":"2026-07-16T00:00:12Z","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":600,"cached_input_tokens":120,"output_tokens":90,"reasoning_output_tokens":12,"total_tokens":690},"last_token_usage":{"input_tokens":200,"cached_input_tokens":40,"output_tokens":35,"reasoning_output_tokens":4,"total_tokens":235}}}}

        """.utf8))
        try materialized.write(to: plainURL)
        try FileManager.default.removeItem(at: compressed)
        try setMtime(Date(timeIntervalSince1970: 2_000), of: plainURL)

        let second = await CodexJSONLScanner.scan(previous: first.newState, roots: [sessions, archived], indexedTitles: [:])
        XCTAssertEqual(second.entries.count, 1)
        XCTAssertNil(second.newState[id]?.fileSize, "回到明文后按 offset 与文件大小判断")
    }

    /// 解压过渡期明文与压缩并存：只读明文一份。
    func testCodexPlainSiblingHidesCompressedCopy() async throws {
        let (sessions, archived) = try makeCodexRoots()
        let id = "aaaaaaa5-5555-4555-8555-555555555555"
        let plain = try copyFixture(
            named: "codex-fast-scan",
            to: sessions.appendingPathComponent("rollout-2026-07-16T00-00-00-\(id).jsonl")
        )
        try DshTestFixtures.frame(try codexFixtureData()).write(to: URL(fileURLWithPath: plain.path + ".zst"))

        let files = JSONLDirectoryEnumerator.enumerate(at: sessions, includeZstd: true).files
        XCTAssertEqual(files.map(\.path), [plain.path])
        XCTAssertEqual(JSONLDirectoryEnumerator.enumerate(at: sessions).files.count, 1, "默认不收压缩日志")

        let result = await CodexJSONLScanner.scan(previous: [:], roots: [sessions, archived], indexedTitles: [:])
        XCTAssertEqual(result.filesScanned, 1)
        XCTAssertEqual(result.entries.count, 3)
    }

    func testCodexCorruptedCompressedRolloutIsReportedWithoutAdvancing() async throws {
        let (sessions, archived) = try makeCodexRoots()
        let id = "aaaaaaa6-6666-4666-8666-666666666666"
        var frame = try DshTestFixtures.frame(try codexFixtureData())
        frame.removeLast(frame.count / 2)
        try frame.write(to: sessions.appendingPathComponent("rollout-2026-07-16T00-00-00-\(id).jsonl.zst"))

        let result = await CodexJSONLScanner.scan(previous: [:], roots: [sessions, archived], indexedTitles: [:])
        XCTAssertEqual(result.failedFileCount, 1)
        XCTAssertTrue(result.entries.isEmpty)
        XCTAssertEqual(result.newState[id]?.offset, 0)
    }

    func testSourceExistsAcceptsEitherRolloutForm() throws {
        let plain = tempDir.appendingPathComponent("rollout-a.jsonl")
        let compressed = URL(fileURLWithPath: plain.path + ".zst")
        XCTAssertFalse(JSONLDirectoryEnumerator.sourceExists(atPath: plain.path))

        try Data().write(to: compressed)
        XCTAssertTrue(JSONLDirectoryEnumerator.sourceExists(atPath: plain.path), "明文已被压缩")
        try FileManager.default.removeItem(at: compressed)

        try Data().write(to: plain)
        XCTAssertTrue(JSONLDirectoryEnumerator.sourceExists(atPath: compressed.path), "压缩日志已解压回明文")
    }

    // MARK: - Codex fork 重放去重

    private static let forkParentID = "019daa2f-0000-7000-8000-000000000001"
    private static let forkChildID = "019daa54-0000-7000-8000-000000000002"
    private static let forkFreshID = "019daa77-0000-7000-8000-000000000003"

    /// 三条真实调用；子会话 fork 时会把它们原样重放进自己的 JSONL。
    private static func forkParentBody() -> String {
        """
        {"timestamp":"2026-07-16T00:00:00Z","type":"session_meta","payload":{"id":"\(forkParentID)","cwd":"/tmp/ccbar-fixture"}}
        {"timestamp":"2026-07-16T00:00:01Z","type":"turn_context","payload":{"model":"gpt-5.6-sol"}}
        {"timestamp":"2026-07-16T00:00:02Z","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":100,"cached_input_tokens":20,"output_tokens":10,"reasoning_output_tokens":2,"total_tokens":110},"last_token_usage":{"input_tokens":100,"cached_input_tokens":20,"output_tokens":10,"reasoning_output_tokens":2,"total_tokens":110}}}}
        {"timestamp":"2026-07-16T00:00:03Z","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":250,"cached_input_tokens":50,"output_tokens":30,"reasoning_output_tokens":5,"total_tokens":280},"last_token_usage":{"input_tokens":150,"cached_input_tokens":30,"output_tokens":20,"reasoning_output_tokens":3,"total_tokens":170}}}}
        {"timestamp":"2026-07-16T00:00:04Z","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":350,"cached_input_tokens":70,"output_tokens":45,"reasoning_output_tokens":7,"total_tokens":395},"last_token_usage":{"input_tokens":100,"cached_input_tokens":20,"output_tokens":15,"reasoning_output_tokens":2,"total_tokens":115}}}}

        """
    }

    /// 真实 fork 文件的形状：自身 session_meta（带 forked_from_id）→ 父会话 session_meta 原样重放
    /// → 父会话全部 token_count 原样重放（只改写 timestamp）→ fork 之后的新调用。
    /// 关键点是新调用之后**不会**再写一条自身的 session_meta，因此它们同样处在父会话 id 之下。
    private static func forkChildBody() -> String {
        """
        {"timestamp":"2026-07-16T01:00:00Z","type":"session_meta","payload":{"id":"\(forkChildID)","forked_from_id":"\(forkParentID)","cwd":"/tmp/ccbar-fixture"}}
        {"timestamp":"2026-07-16T01:00:00Z","type":"session_meta","payload":{"id":"\(forkParentID)","cwd":"/tmp/ccbar-fixture"}}
        {"timestamp":"2026-07-16T01:00:00Z","type":"turn_context","payload":{"model":"gpt-5.6-sol"}}
        {"timestamp":"2026-07-16T01:00:00Z","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":100,"cached_input_tokens":20,"output_tokens":10,"reasoning_output_tokens":2,"total_tokens":110},"last_token_usage":{"input_tokens":100,"cached_input_tokens":20,"output_tokens":10,"reasoning_output_tokens":2,"total_tokens":110}}}}
        {"timestamp":"2026-07-16T01:00:00Z","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":250,"cached_input_tokens":50,"output_tokens":30,"reasoning_output_tokens":5,"total_tokens":280},"last_token_usage":{"input_tokens":150,"cached_input_tokens":30,"output_tokens":20,"reasoning_output_tokens":3,"total_tokens":170}}}}
        {"timestamp":"2026-07-16T01:00:00Z","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":350,"cached_input_tokens":70,"output_tokens":45,"reasoning_output_tokens":7,"total_tokens":395},"last_token_usage":{"input_tokens":100,"cached_input_tokens":20,"output_tokens":15,"reasoning_output_tokens":2,"total_tokens":115}}}}
        {"timestamp":"2026-07-16T01:05:00Z","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":470,"cached_input_tokens":95,"output_tokens":63,"reasoning_output_tokens":9,"total_tokens":533},"last_token_usage":{"input_tokens":120,"cached_input_tokens":25,"output_tokens":18,"reasoning_output_tokens":2,"total_tokens":138}}}}
        {"timestamp":"2026-07-16T01:10:00Z","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":585,"cached_input_tokens":115,"output_tokens":79,"reasoning_output_tokens":11,"total_tokens":664},"last_token_usage":{"input_tokens":115,"cached_input_tokens":20,"output_tokens":16,"reasoning_output_tokens":2,"total_tokens":131}}}}

        """
    }

    /// 同样带 forked_from_id，但 Codex 没有重放任何历史（累计值从 0 起算）——真实日志里存在这种
    /// fork。按 forked_from_id 一刀切排除会把它整段真实用量删掉。
    private static func forkFreshBody() -> String {
        """
        {"timestamp":"2026-07-16T02:00:00Z","type":"session_meta","payload":{"id":"\(forkFreshID)","forked_from_id":"\(forkParentID)","cwd":"/tmp/ccbar-fixture"}}
        {"timestamp":"2026-07-16T02:00:01Z","type":"turn_context","payload":{"model":"gpt-5.6-sol"}}
        {"timestamp":"2026-07-16T02:00:02Z","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":80,"cached_input_tokens":10,"output_tokens":10,"reasoning_output_tokens":1,"total_tokens":90},"last_token_usage":{"input_tokens":80,"cached_input_tokens":10,"output_tokens":10,"reasoning_output_tokens":1,"total_tokens":90}}}}

        """
    }

    @discardableResult
    private func writeSession(_ body: String, id: String, at hour: String, in directory: URL) throws -> URL {
        let url = directory.appendingPathComponent("rollout-2026-07-16T\(hour)-00-00-\(id).jsonl")
        try Data(body.utf8).write(to: url)
        return url
    }

    /// fork 会话重放的父会话历史不能重复计费，fork 之后的新调用必须照常入账，
    /// 且新调用要归到 fork 自己的会话 key（旧实现会被重放进来的父 session_meta 串走）。
    func testCodexForkReplayNotDoubleCounted() async throws {
        let sessions = tempDir.appendingPathComponent("sessions", isDirectory: true)
        let archived = tempDir.appendingPathComponent("archived", isDirectory: true)
        try FileManager.default.createDirectory(at: sessions, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: archived, withIntermediateDirectories: true)
        try writeSession(Self.forkParentBody(), id: Self.forkParentID, at: "00", in: sessions)
        try writeSession(Self.forkChildBody(), id: Self.forkChildID, at: "01", in: sessions)

        let result = await CodexJSONLScanner.scan(previous: [:], roots: [sessions, archived], indexedTitles: [:])

        XCTAssertEqual(result.entries.count, 5, "父会话 3 条 + fork 后新增 2 条，重放的 3 条必须被去掉")
        let parentEntries = result.entries.filter { $0.conversationKey == "codex:\(Self.forkParentID)" }
        let childEntries = result.entries.filter { $0.conversationKey == "codex:\(Self.forkChildID)" }
        XCTAssertEqual(parentEntries.count, 3)
        XCTAssertEqual(childEntries.count, 2, "fork 之后的新调用应归到 fork 自己的会话")
        XCTAssertEqual(childEntries.map(\.inputTokens).sorted(), [95, 95])
        XCTAssertEqual(childEntries.map(\.outputTokens).sorted(), [16, 18])
        // 重放行的 timestamp 被改写成 fork 时刻；保留下来的必须是父文件里的原始时间。
        XCTAssertTrue(
            parentEntries.allSatisfy { $0.timestamp < Date(timeIntervalSince1970: 1_784_161_800) },
            "保留的应是父文件里带原始时间的记录，而不是 fork 时刻的副本"
        )
        let seeds = Dictionary(uniqueKeysWithValues: result.conversationSeeds.map { ($0.key, $0) })
        XCTAssertNil(seeds["codex:\(Self.forkChildID)"]?.continuationKey, "手动 fork 不是续接段")
        XCTAssertNil(seeds["codex:\(Self.forkParentID)"]?.continuationKey)
    }

    /// 扫描顺序不能影响结果：父会话按 UUIDv7 排序永远先于它的 fork。
    /// 若顺序漂移，被保留的会变成 timestamp 已被改写的重放副本，用量会归错天。
    func testCodexForkDedupIsOrderIndependent() async throws {
        let sessions = tempDir.appendingPathComponent("sessions", isDirectory: true)
        let archived = tempDir.appendingPathComponent("archived", isDirectory: true)
        try FileManager.default.createDirectory(at: sessions, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: archived, withIntermediateDirectories: true)
        // 先写 fork，再写父会话，让目录枚举顺序与会话创建顺序相反。
        try writeSession(Self.forkChildBody(), id: Self.forkChildID, at: "01", in: sessions)
        try writeSession(Self.forkParentBody(), id: Self.forkParentID, at: "00", in: sessions)

        let result = await CodexJSONLScanner.scan(previous: [:], roots: [sessions, archived], indexedTitles: [:])

        XCTAssertEqual(result.entries.count, 5)
        XCTAssertEqual(result.entries.filter { $0.conversationKey == "codex:\(Self.forkParentID)" }.count, 3)
    }

    /// 带 forked_from_id 但没有重放历史的 fork，用量一条都不能少。
    func testCodexForkWithoutReplayKeepsAllUsage() async throws {
        let sessions = tempDir.appendingPathComponent("sessions", isDirectory: true)
        let archived = tempDir.appendingPathComponent("archived", isDirectory: true)
        try FileManager.default.createDirectory(at: sessions, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: archived, withIntermediateDirectories: true)
        try writeSession(Self.forkParentBody(), id: Self.forkParentID, at: "00", in: sessions)
        try writeSession(Self.forkFreshBody(), id: Self.forkFreshID, at: "02", in: sessions)

        let result = await CodexJSONLScanner.scan(previous: [:], roots: [sessions, archived], indexedTitles: [:])

        XCTAssertEqual(result.entries.count, 4)
        XCTAssertEqual(result.entries.filter { $0.conversationKey == "codex:\(Self.forkFreshID)" }.count, 1)
    }

    /// 增量场景：父会话上一轮已扫完，本轮才出现 fork 文件——去重必须靠持久化的 seen 集合。
    func testCodexForkReplayDedupedAcrossIncrementalScans() async throws {
        let sessions = tempDir.appendingPathComponent("sessions", isDirectory: true)
        let archived = tempDir.appendingPathComponent("archived", isDirectory: true)
        try FileManager.default.createDirectory(at: sessions, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: archived, withIntermediateDirectories: true)
        try writeSession(Self.forkParentBody(), id: Self.forkParentID, at: "00", in: sessions)

        let first = await CodexJSONLScanner.scan(previous: [:], roots: [sessions, archived], indexedTitles: [:])
        XCTAssertEqual(first.entries.count, 3)
        XCTAssertEqual(first.newSeenIds.count, 3)

        try writeSession(Self.forkChildBody(), id: Self.forkChildID, at: "01", in: sessions)
        let second = await CodexJSONLScanner.scan(
            previous: first.newState,
            seenTokenIds: first.newSeenIds,
            roots: [sessions, archived],
            indexedTitles: [:]
        )

        XCTAssertEqual(second.entries.count, 2, "重放段已在上一轮记入 seen，本轮只应收到 fork 后的新调用")
        XCTAssertTrue(second.entries.allSatisfy { $0.conversationKey == "codex:\(Self.forkChildID)" })
    }

    // MARK: - Codex 分页历史分段

    private static let pagedThreadID = "019dbb00-0000-7000-8000-00000000000a"
    private static let pagedSegmentID = "019dbb00-0000-7000-8000-00000000000b"

    private static func pagedOriginalBody() -> String {
        """
        {"timestamp":"2026-07-16T03:00:00Z","type":"session_meta","payload":{"id":"\(pagedThreadID)","cwd":"/tmp/ccbar-fixture"}}
        {"timestamp":"2026-07-16T03:00:01Z","type":"turn_context","payload":{"model":"gpt-6.1-sol"}}
        {"timestamp":"2026-07-16T03:00:02Z","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":100,"cached_input_tokens":0,"output_tokens":10,"reasoning_output_tokens":0,"total_tokens":110},"last_token_usage":{"input_tokens":100,"cached_input_tokens":0,"output_tokens":10,"reasoning_output_tokens":0,"total_tokens":110}}}}

        """
    }

    /// 分页历史的续写分段：文件名末尾是分段自己的 UUID，首行 session_meta 的 id 仍是原对话，
    /// 并带 `history_base.thread_id` 指回它。
    private static func pagedSegmentBody() -> String {
        """
        {"timestamp":"2026-07-16T04:00:00Z","type":"session_meta","payload":{"id":"\(pagedThreadID)","session_id":"\(pagedThreadID)","cwd":"/tmp/ccbar-fixture","history_mode":"paginated","history_base":{"thread_id":"\(pagedThreadID)","end_ordinal_exclusive":1,"end_byte_offset":400}}}
        {"timestamp":"2026-07-16T04:00:01Z","type":"turn_context","payload":{"model":"gpt-6.1-sol"}}
        {"timestamp":"2026-07-16T04:00:02Z","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":250,"cached_input_tokens":0,"output_tokens":30,"reasoning_output_tokens":0,"total_tokens":280},"last_token_usage":{"input_tokens":150,"cached_input_tokens":0,"output_tokens":20,"reasoning_output_tokens":0,"total_tokens":170}}}}

        """
    }

    @discardableResult
    private func writePaginatedSegment(in directory: URL) throws -> URL {
        let url = directory.appendingPathComponent(
            "rollout-2026-07-16T04-00-00-\(Self.pagedThreadID)_\(Self.pagedSegmentID).jsonl"
        )
        try Data(Self.pagedSegmentBody().utf8).write(to: url)
        return url
    }

    /// 同一对话续写进新的 rollout 分段：文件名末尾是分段 id，首行 session_meta 仍是原对话。
    /// 分段要作为续接段挂回原对话（标题用原对话的 thread name），而不是无标题、无项目的新对话。
    func testCodexPaginatedSegmentContinuesOriginalThread() async throws {
        let sessions = tempDir.appendingPathComponent("sessions", isDirectory: true)
        try FileManager.default.createDirectory(at: sessions, withIntermediateDirectories: true)
        let original = sessions.appendingPathComponent("rollout-2026-07-16T03-00-00-\(Self.pagedThreadID).jsonl")
        try Data(Self.pagedOriginalBody().utf8).write(to: original)
        _ = try writePaginatedSegment(in: sessions)

        let titles = [Self.pagedThreadID: "确认 v1 是否开发完成"]
        let first = await CodexJSONLScanner.scan(previous: [:], roots: [sessions], indexedTitles: titles)
        let seeds = Dictionary(uniqueKeysWithValues: first.conversationSeeds.map { ($0.key, $0) })
        let segmentSeed = try XCTUnwrap(seeds["codex:\(Self.pagedSegmentID)"])
        XCTAssertEqual(segmentSeed.continuationKey, "codex:\(Self.pagedThreadID)")
        XCTAssertEqual(segmentSeed.title, "确认 v1 是否开发完成", "分段没有用户消息时用原对话标题兜底")
        XCTAssertEqual(segmentSeed.project.name, "ccbar-fixture", "分段的 cwd 要采信")
        XCTAssertNil(seeds["codex:\(Self.pagedThreadID)"]?.continuationKey, "原对话本身不是续接段")
        XCTAssertEqual(first.newState[Self.pagedSegmentID]?.codexContinuationOf, Self.pagedThreadID)
        XCTAssertEqual(first.entries.filter { $0.conversationKey == "codex:\(Self.pagedSegmentID)" }.count, 1,
                       "分段用量仍按自身 key 记账，合并只发生在展示层")

        // 文件不变时从保存的状态带出续接关系与标题。
        let second = await CodexJSONLScanner.scan(previous: first.newState, roots: [sessions], indexedTitles: titles)
        let unchangedSeed = try XCTUnwrap(second.conversationSeeds.first { $0.key == "codex:\(Self.pagedSegmentID)" })
        XCTAssertEqual(unchangedSeed.continuationKey, "codex:\(Self.pagedThreadID)")
        XCTAssertEqual(unchangedSeed.title, "确认 v1 是否开发完成")
    }

    /// 旧版本扫过的分段没有记录续接关系，offset 又已在文件中段：升级后靠首行补读补上。
    func testCodexPaginatedSegmentBackfillsContinuationOnResume() async throws {
        let sessions = tempDir.appendingPathComponent("sessions", isDirectory: true)
        try FileManager.default.createDirectory(at: sessions, withIntermediateDirectories: true)
        let original = sessions.appendingPathComponent("rollout-2026-07-16T03-00-00-\(Self.pagedThreadID).jsonl")
        try Data(Self.pagedOriginalBody().utf8).write(to: original)
        let segment = try writePaginatedSegment(in: sessions)

        let first = await CodexJSONLScanner.scan(previous: [:], roots: [sessions], indexedTitles: [:])
        var stale = first.newState
        stale[Self.pagedSegmentID]?.codexContinuationOf = nil
        stale[Self.pagedSegmentID]?.conversationCwd = ""
        XCTAssertNil(stale[Self.pagedSegmentID]?.codexContinuationOf, "模拟升级前的旧状态")

        let appended = """
        {"timestamp":"2026-07-16T04:00:03Z","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":400,"cached_input_tokens":0,"output_tokens":50,"reasoning_output_tokens":0,"total_tokens":450},"last_token_usage":{"input_tokens":150,"cached_input_tokens":0,"output_tokens":20,"reasoning_output_tokens":0,"total_tokens":170}}}}

        """
        let handle = try FileHandle(forWritingTo: segment)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: Data(appended.utf8))

        let second = await CodexJSONLScanner.scan(
            previous: stale,
            roots: [sessions],
            indexedTitles: [Self.pagedThreadID: "确认 v1 是否开发完成"]
        )
        XCTAssertEqual(second.entries.count, 1, "只读追加的那一条")
        XCTAssertEqual(second.newState[Self.pagedSegmentID]?.codexContinuationOf, Self.pagedThreadID)
        let seed = try XCTUnwrap(second.conversationSeeds.first { $0.key == "codex:\(Self.pagedSegmentID)" })
        XCTAssertEqual(seed.continuationKey, "codex:\(Self.pagedThreadID)")
        XCTAssertEqual(seed.title, "确认 v1 是否开发完成")
        XCTAssertEqual(seed.project.name, "ccbar-fixture", "旧状态里被跳过的 cwd 一并补齐")
    }

    // MARK: - Claude

    /// Claude 同样按 alive 清理已删除文件的 watermark。
    func testClaudeDeletedFileClearsWatermark() throws {
        let projects = tempDir.appendingPathComponent("projects", isDirectory: true)
        let container = projects.appendingPathComponent("fixture-project", isDirectory: true)
        try FileManager.default.createDirectory(at: container, withIntermediateDirectories: true)
        let file = try copyFixture(
            named: "claude-fast-scan",
            to: container.appendingPathComponent("session-a.jsonl")
        )
        let index = ConversationTitleIndex.ClaudeIndex(titles: [:], projects: [:])

        let first = ClaudeJSONLScanner.scan(previous: [:], seenMessageIds: [], root: projects, conversationIndex: index)
        XCTAssertFalse(first.entries.isEmpty)
        XCTAssertNotNil(first.newState[file.path])

        try FileManager.default.removeItem(at: file)
        let second = ClaudeJSONLScanner.scan(previous: first.newState, seenMessageIds: [], root: projects, conversationIndex: index)
        XCTAssertNil(second.newState[file.path], "已删除文件的 watermark 应被清理")
    }

    /// minimumMtime 只返回窗口内的文件（周期受限重建语义）。
    func testClaudeMinimumMtimeFiltersOldFiles() throws {
        let projects = tempDir.appendingPathComponent("projects", isDirectory: true)
        let c1 = projects.appendingPathComponent("p1", isDirectory: true)
        let c2 = projects.appendingPathComponent("p2", isDirectory: true)
        try FileManager.default.createDirectory(at: c1, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: c2, withIntermediateDirectories: true)
        let old = try copyFixture(named: "claude-fast-scan", to: c1.appendingPathComponent("old.jsonl"))
        let newer = try copyFixture(named: "claude-fast-scan", to: c2.appendingPathComponent("new.jsonl"))
        try setMtime(Date(timeIntervalSince1970: 1_000), of: old)
        try setMtime(Date(timeIntervalSince1970: 2_000), of: newer)
        let index = ConversationTitleIndex.ClaudeIndex(titles: [:], projects: [:])

        let filtered = ClaudeJSONLScanner.scan(
            previous: [:],
            seenMessageIds: [],
            root: projects,
            conversationIndex: index,
            minimumMtime: Date(timeIntervalSince1970: 1_500)
        )
        XCTAssertEqual(filtered.filesScanned, 1)
        XCTAssertNil(filtered.newState[old.path])
        XCTAssertNotNil(filtered.newState[newer.path])
    }

    // MARK: - 首字延迟与输出速度

    private func writeLines(_ lines: [String], to url: URL) throws {
        try (lines.joined(separator: "\n") + "\n").write(to: url, atomically: true, encoding: .utf8)
    }

    private func appendLines(_ lines: [String], to url: URL) throws {
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: Data((lines.joined(separator: "\n") + "\n").utf8))
    }

    private func claudeUser(_ time: String, toolResult: Bool = false) -> String {
        let content = toolResult ? #"[{"type":"tool_result","tool_use_id":"t1","content":"ok"}]"# : #""hi""#
        return #"{"type":"user","sessionId":"timing-session","timestamp":"2026-10-15T00:00:\#(time)Z","message":{"role":"user","content":\#(content)}}"#
    }

    private func claudeAssistant(_ time: String, id: String, block: String, output: Int, thinkingMs: Int? = nil) -> String {
        let thinking = thinkingMs.map { #","thinkingDurationMs":\#($0)"# } ?? ""
        return #"{"type":"assistant","sessionId":"timing-session","cwd":"/tmp/ccbar-fixture","timestamp":"2026-10-15T00:00:\#(time)Z"\#(thinking),"message":{"id":"\#(id)","model":"claude-opus-5-5","stop_reason":"tool_use","content":[{"type":"\#(block)"}],"usage":{"input_tokens":10,"output_tokens":\#(output),"speed":"standard"}}}"#
    }

    /// 首字 = thinking 块写入时间 − thinkingDurationMs；工具结果穿插在同一消息的块之间不算结束；
    /// 不以 thinking 开头的消息不给计时；读到末尾明显没写完的消息留到下一轮整条重读。
    func testClaudeTimingFromThinkingDuration() throws {
        let projects = tempDir.appendingPathComponent("projects", isDirectory: true)
        let container = projects.appendingPathComponent("timing", isDirectory: true)
        try FileManager.default.createDirectory(at: container, withIntermediateDirectories: true)
        let file = container.appendingPathComponent("timing-session.jsonl")
        try writeLines([
            claudeUser("00.000"),
            claudeAssistant("03.000", id: "m1", block: "thinking", output: 400, thinkingMs: 1000),
            claudeUser("04.000", toolResult: true),
            claudeAssistant("06.000", id: "m1", block: "tool_use", output: 400),
            claudeUser("07.000", toolResult: true),
            claudeAssistant("09.000", id: "m2", block: "text", output: 150),
            claudeUser("10.000", toolResult: true),
            claudeAssistant("13.000", id: "m3", block: "thinking", output: 200, thinkingMs: 500),
        ], to: file)
        let index = ConversationTitleIndex.ClaudeIndex(titles: [:], projects: [:])

        let result = ClaudeJSONLScanner.scan(previous: [:], seenMessageIds: [], root: projects, conversationIndex: index)
        let byOutput = Dictionary(uniqueKeysWithValues: result.entries.map { ($0.outputTokens, $0) })
        XCTAssertEqual(byOutput[400]?.timing, RequestTiming(firstTokenMs: 2000, generationMs: 4000))
        XCTAssertNil(byOutput[150]?.timing, "以文本开头的消息没有首字时间")
        XCTAssertNil(byOutput[200], "收在 thinking 块的末尾消息还没写完，本轮不入账")
        XCTAssertTrue(result.hasDeferredMessages)
        XCTAssertEqual(result.newState[file.path]?.claudeLastInputMs, 1_792_022_410_000)

        try appendLines([claudeAssistant("15.000", id: "m3", block: "tool_use", output: 200)], to: file)
        let second = ClaudeJSONLScanner.scan(
            previous: result.newState, seenMessageIds: result.newSeenIds, root: projects, conversationIndex: index
        )
        XCTAssertEqual(second.entries.map(\.outputTokens), [200], "退回的消息下一轮只入账一次")
        XCTAssertEqual(second.entries.first?.timing, RequestTiming(firstTokenMs: 2500, generationMs: 2500))
        XCTAssertFalse(second.hasDeferredMessages, "收在工具调用、与 stop_reason 对得上的末尾消息当场结束")
    }

    /// 请求发出时间跨增量扫描续接：上一轮只读到提示词，这一轮才读到回复。
    func testClaudeTimingCarriesRequestStartAcrossScans() throws {
        let projects = tempDir.appendingPathComponent("projects", isDirectory: true)
        let container = projects.appendingPathComponent("timing", isDirectory: true)
        try FileManager.default.createDirectory(at: container, withIntermediateDirectories: true)
        let file = container.appendingPathComponent("timing-session.jsonl")
        try writeLines([claudeUser("00.000")], to: file)
        let index = ConversationTitleIndex.ClaudeIndex(titles: [:], projects: [:])
        let first = ClaudeJSONLScanner.scan(previous: [:], seenMessageIds: [], root: projects, conversationIndex: index)
        XCTAssertTrue(first.entries.isEmpty)

        try appendLines([
            claudeAssistant("02.500", id: "m1", block: "thinking", output: 300, thinkingMs: 1500),
            #"{"type":"system","subtype":"stop_hook_summary","sessionId":"timing-session","timestamp":"2026-10-15T00:00:04.000Z"}"#,
        ], to: file)
        let second = ClaudeJSONLScanner.scan(
            previous: first.newState, seenMessageIds: first.newSeenIds, root: projects, conversationIndex: index
        )
        XCTAssertEqual(second.entries.first?.timing, RequestTiming(firstTokenMs: 1000, generationMs: 1500))
    }

    /// 一轮的最终回答后面常常没有别的行：文件闲置够久时末尾的消息也给计时。
    func testClaudeTimingClosesLastMessageWhenFileIdle() throws {
        let projects = tempDir.appendingPathComponent("projects", isDirectory: true)
        let container = projects.appendingPathComponent("timing", isDirectory: true)
        try FileManager.default.createDirectory(at: container, withIntermediateDirectories: true)
        let file = container.appendingPathComponent("timing-session.jsonl")
        try writeLines([
            claudeUser("00.000"),
            claudeAssistant("03.000", id: "m1", block: "thinking", output: 300, thinkingMs: 1000),
            claudeAssistant("06.000", id: "m1", block: "text", output: 300),
        ], to: file)
        let idleSince = Date().addingTimeInterval(-(ClaudeJSONLScanner.TimingTracker.idleCloseSeconds + 5))
        try FileManager.default.setAttributes([.modificationDate: idleSince], ofItemAtPath: file.path)
        let index = ConversationTitleIndex.ClaudeIndex(titles: [:], projects: [:])

        let result = ClaudeJSONLScanner.scan(previous: [:], seenMessageIds: [], root: projects, conversationIndex: index)
        XCTAssertEqual(result.entries.first?.timing, RequestTiming(firstTokenMs: 2000, generationMs: 4000))
    }

    // MARK: - Claude 续接 / 分叉 / 标题

    private func claudeMessage(session: String, id: String, minute: Int, output: Int) -> String {
        #"{"type":"assistant","sessionId":"\#(session)","cwd":"/tmp/ccbar-fixture","timestamp":"2026-10-15T00:\#(String(format: "%02d", minute)):00Z","message":{"id":"\#(id)","model":"claude-opus-5-5","stop_reason":"end_turn","usage":{"input_tokens":10,"output_tokens":\#(output)}}}"#
    }

    private func claudeContainer() throws -> (projects: URL, container: URL) {
        let projects = tempDir.appendingPathComponent("projects", isDirectory: true)
        let container = projects.appendingPathComponent("continuation", isDirectory: true)
        try FileManager.default.createDirectory(at: container, withIntermediateDirectories: true)
        return (projects, container)
    }

    /// 续接把上一段历史复制进新文件并改写成新 sessionId：记下续接关系，复制的消息不重复计。
    /// 分叉保留原 sessionId：不算续接，仍是独立对话。
    func testClaudeContinuationIsLinkedAndForkStaysIndependent() throws {
        let (projects, container) = try claudeContainer()
        try writeLines([
            claudeMessage(session: "aaaa", id: "a1", minute: 0, output: 10),
            claudeMessage(session: "aaaa", id: "a2", minute: 1, output: 20),
        ], to: container.appendingPathComponent("aaaa.jsonl"))
        try writeLines([
            claudeMessage(session: "bbbb", id: "a1", minute: 0, output: 10),
            claudeMessage(session: "bbbb", id: "a2", minute: 1, output: 20),
            claudeMessage(session: "bbbb", id: "b1", minute: 2, output: 30),
        ], to: container.appendingPathComponent("bbbb.jsonl"))
        try writeLines([
            claudeMessage(session: "aaaa", id: "a1", minute: 0, output: 10),
            claudeMessage(session: "ffff", id: "f1", minute: 3, output: 40),
        ], to: container.appendingPathComponent("ffff.jsonl"))
        let index = ConversationTitleIndex.ClaudeIndex(titles: [:], projects: [:])

        let result = ClaudeJSONLScanner.scan(previous: [:], seenMessageIds: [], root: projects, conversationIndex: index)
        XCTAssertEqual(result.entries.map(\.outputTokens).sorted(), [10, 20, 30, 40])
        let seeds = Dictionary(uniqueKeysWithValues: result.conversationSeeds.map { ($0.key, $0) })
        XCTAssertEqual(seeds["claude:bbbb"]?.continuationKey, "claude:aaaa")
        XCTAssertNil(seeds["claude:ffff"]?.continuationKey, "分叉是独立对话")
        XCTAssertNil(seeds["claude:aaaa"]?.continuationKey)

        // 文件没变时从保存的状态带出续接关系。
        let unchanged = ClaudeJSONLScanner.scan(
            previous: result.newState, seenMessageIds: result.newSeenIds, root: projects, conversationIndex: index
        )
        XCTAssertTrue(unchanged.entries.isEmpty)
        XCTAssertEqual(
            unchanged.conversationSeeds.first { $0.key == "claude:bbbb" }?.continuationKey, "claude:aaaa"
        )
    }

    /// 增量扫描时上一段早已入账：靠账本查到复制消息原来计在哪个对话。
    func testClaudeContinuationFoundThroughLedgerAcrossScans() throws {
        let (projects, container) = try claudeContainer()
        try writeLines([
            claudeMessage(session: "aaaa", id: "a1", minute: 0, output: 10),
        ], to: container.appendingPathComponent("aaaa.jsonl"))
        let index = ConversationTitleIndex.ClaudeIndex(titles: [:], projects: [:])
        let first = ClaudeJSONLScanner.scan(previous: [:], seenMessageIds: [], root: projects, conversationIndex: index)

        try writeLines([
            claudeMessage(session: "bbbb", id: "a1", minute: 0, output: 10),
            claudeMessage(session: "bbbb", id: "b1", minute: 2, output: 30),
        ], to: container.appendingPathComponent("bbbb.jsonl"))
        let ledger = first.ledger
        let second = ClaudeJSONLScanner.scan(
            previous: first.newState,
            seenMessageIds: first.newSeenIds,
            knownOwner: { digest in ledger.first { $0.value.contains(digest) }?.key },
            root: projects,
            conversationIndex: index
        )
        XCTAssertEqual(second.entries.map(\.outputTokens), [30])
        XCTAssertEqual(second.conversationSeeds.first { $0.key == "claude:bbbb" }?.continuationKey, "claude:aaaa")
    }

    /// 标题优先用桌面端的 custom-title.json，其次 history.jsonl，最后首条用户消息；注入的标签块不进标题。
    func testClaudeTitlePrefersDesktopCustomTitle() throws {
        let (projects, container) = try claudeContainer()
        try writeLines([
            #"{"type":"user","sessionId":"cccc","timestamp":"2026-10-15T00:00:00Z","message":{"role":"user","content":"首条消息<system-reminder>注入内容</system-reminder>"}}"#,
            claudeMessage(session: "cccc", id: "c1", minute: 1, output: 10),
        ], to: container.appendingPathComponent("cccc.jsonl"))
        let fallback = ClaudeJSONLScanner.scan(
            previous: [:], seenMessageIds: [], root: projects,
            conversationIndex: ConversationTitleIndex.ClaudeIndex(titles: [:], projects: [:])
        )
        XCTAssertEqual(fallback.conversationSeeds.first?.title, "首条消息")

        let withHistory = ConversationTitleIndex.ClaudeIndex(titles: ["cccc": "history 标题"], projects: [:])
        let sessionDirectory = container.appendingPathComponent("cccc", isDirectory: true)
        try FileManager.default.createDirectory(at: sessionDirectory, withIntermediateDirectories: true)
        try Data(#"{"customTitle":"桌面端标题"}"#.utf8).write(to: sessionDirectory.appendingPathComponent("custom-title.json"))
        let desktop = ClaudeJSONLScanner.scan(previous: [:], seenMessageIds: [], root: projects, conversationIndex: withHistory)
        XCTAssertEqual(desktop.conversationSeeds.first?.title, "桌面端标题")

        try FileManager.default.removeItem(at: sessionDirectory.appendingPathComponent("custom-title.json"))
        let history = ClaudeJSONLScanner.scan(previous: [:], seenMessageIds: [], root: projects, conversationIndex: withHistory)
        XCTAssertEqual(history.conversationSeeds.first?.title, "history 标题")
    }

    func testTitleCleanRemovesInjectedBlocks() {
        XCTAssertEqual(ConversationTitleIndex.clean("修复登录 <system-reminder>a\nb</system-reminder> 问题"), "修复登录 问题")
        XCTAssertEqual(ConversationTitleIndex.clean("看看这个<system-reminder>没有闭合"), "看看这个")
        XCTAssertNil(ConversationTitleIndex.clean("<system-reminder>只有注入</system-reminder>"))
        XCTAssertEqual(ConversationTitleIndex.clean("保留 <b>用户</b> 标签"), "保留 <b>用户</b> 标签")
    }

    private func codexItem(_ ms: Int, type: String, started: Int, loggedMs: Int? = nil) -> String {
        let logged = Date(timeIntervalSince1970: Double(loggedMs ?? ms) / 1000)
        let stamp = ISO8601DateFormatter.ccbarTestFormatter.string(from: logged)
        return #"{"timestamp":"\#(stamp)","type":"event_msg","payload":{"type":"item_completed","item":{"type":"\#(type)"},"started_at_ms":\#(started),"completed_at_ms":\#(ms)}}"#
    }

    private func codexUsageRecord(_ ms: Int, output: Int) -> String {
        let stamp = ISO8601DateFormatter.ccbarTestFormatter.string(from: Date(timeIntervalSince1970: Double(ms) / 1000))
        return #"{"timestamp":"\#(stamp)","type":"token_usage_record","payload":{"usage":{"input_tokens":100,"cached_input_tokens":0,"output_tokens":\#(output)}}}"#
    }

    private func codexTokenCount(_ ms: Int, output: Int, total: Int) -> String {
        let stamp = ISO8601DateFormatter.ccbarTestFormatter.string(from: Date(timeIntervalSince1970: Double(ms) / 1000))
        return #"{"timestamp":"\#(stamp)","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":\#(total),"cached_input_tokens":0,"output_tokens":\#(total),"total_tokens":\#(total * 2)},"last_token_usage":{"input_tokens":100,"cached_input_tokens":0,"output_tokens":\#(output),"total_tokens":\#(100 + output)}}}}"#
    }

    /// 请求发出 = 上一个非模型条目完成；首字 = 第一个模型条目开始；结束 = token_usage_record。
    /// 外层 timestamp 与条目毫秒相差过大（fork 重放改写过时间）的条目不参与计时。
    func testCodexTimingPairsUsageRecordWithTokenCount() async throws {
        let sessions = tempDir.appendingPathComponent("sessions", isDirectory: true)
        try FileManager.default.createDirectory(at: sessions, withIntermediateDirectories: true)
        let id = "33333333-3333-4333-8333-333333333333"
        let t0 = 1_792_022_400_000
        let file = sessions.appendingPathComponent("rollout-2026-10-15T00-00-00-\(id).jsonl")
        try writeLines([
            #"{"timestamp":"2026-10-15T00:00:00Z","type":"session_meta","payload":{"id":"\#(id)","cwd":"/tmp/ccbar-fixture"}}"#,
            #"{"timestamp":"2026-10-15T00:00:00Z","type":"turn_context","payload":{"model":"gpt-6.1-sol"}}"#,
            codexItem(t0, type: "UserMessage", started: t0),
            codexItem(t0 + 5_000, type: "Reasoning", started: t0 + 2_000),
            codexItem(t0 + 5_500, type: "AgentMessage", started: t0 + 5_000),
            codexUsageRecord(t0 + 6_000, output: 300),
            codexItem(t0 + 9_000, type: "CommandExecution", started: t0 + 6_500),
            codexTokenCount(t0 + 9_001, output: 300, total: 1_000),
            codexItem(t0 + 12_000, type: "Reasoning", started: t0 + 10_000, loggedMs: t0 + 60_000),
            codexUsageRecord(t0 + 13_000, output: 200),
            codexTokenCount(t0 + 13_001, output: 200, total: 2_000),
        ], to: file)

        let result = await CodexJSONLScanner.scan(previous: [:], roots: [sessions], indexedTitles: [:])
        XCTAssertEqual(result.entries.count, 2)
        let byOutput = Dictionary(uniqueKeysWithValues: result.entries.map { ($0.outputTokens, $0) })
        XCTAssertEqual(byOutput[300]?.timing, RequestTiming(firstTokenMs: 2000, generationMs: 4000))
        XCTAssertNil(byOutput[200]?.timing, "时间被改写过的条目不参与计时")
        XCTAssertNil(result.newState[id]?.codexTiming?.pending)
    }

    /// 中断的请求等不到 token_usage_record：它的首字时间不能串到下一回合的第一次请求上。
    func testCodexTimingDiscardsAbortedTurn() async throws {
        let sessions = tempDir.appendingPathComponent("sessions", isDirectory: true)
        try FileManager.default.createDirectory(at: sessions, withIntermediateDirectories: true)
        let id = "44444444-4444-4444-8444-444444444444"
        let t0 = 1_792_022_400_000
        let stamp = { (ms: Int) in ISO8601DateFormatter.ccbarTestFormatter.string(from: Date(timeIntervalSince1970: Double(ms) / 1000)) }
        let file = sessions.appendingPathComponent("rollout-2026-10-15T00-00-00-\(id).jsonl")
        try writeLines([
            #"{"timestamp":"2026-10-15T00:00:00Z","type":"session_meta","payload":{"id":"\#(id)","cwd":"/tmp/ccbar-fixture"}}"#,
            #"{"timestamp":"2026-10-15T00:00:00Z","type":"turn_context","payload":{"model":"gpt-6.1-sol"}}"#,
            codexItem(t0, type: "UserMessage", started: t0),
            codexItem(t0 + 3_000, type: "Reasoning", started: t0 + 1_000),
            codexTokenCount(t0 + 3_500, output: 50, total: 1_000),
            #"{"timestamp":"\#(stamp(t0 + 4_000))","type":"event_msg","payload":{"type":"turn_aborted"}}"#,
            #"{"timestamp":"\#(stamp(t0 + 600_000))","type":"event_msg","payload":{"type":"task_started"}}"#,
            codexItem(t0 + 600_000, type: "UserMessage", started: t0 + 600_000),
            codexItem(t0 + 605_000, type: "Reasoning", started: t0 + 602_000),
            codexUsageRecord(t0 + 606_000, output: 300),
            codexTokenCount(t0 + 606_001, output: 300, total: 2_000),
        ], to: file)

        let result = await CodexJSONLScanner.scan(previous: [:], roots: [sessions], indexedTitles: [:])
        let byOutput = Dictionary(uniqueKeysWithValues: result.entries.map { ($0.outputTokens, $0) })
        XCTAssertNil(byOutput[50]?.timing, "中断的请求没有 token_usage_record，不计时")
        XCTAssertEqual(byOutput[300]?.timing, RequestTiming(firstTokenMs: 2000, generationMs: 4000))
    }

    /// 请求已开始出字时收到子智能体消息，Codex 会放弃这次调用、带着消息重新发起：
    /// 首字时间作废，以消息送达时间作为新的请求发出时间。
    func testCodexTimingRestartsAfterInterAgentMessage() async throws {
        let sessions = tempDir.appendingPathComponent("sessions", isDirectory: true)
        try FileManager.default.createDirectory(at: sessions, withIntermediateDirectories: true)
        let id = "55555555-5555-4555-8555-555555555555"
        let t0 = 1_792_022_400_000
        let stamp = { (ms: Int) in ISO8601DateFormatter.ccbarTestFormatter.string(from: Date(timeIntervalSince1970: Double(ms) / 1000)) }
        let file = sessions.appendingPathComponent("rollout-2026-10-15T00-00-00-\(id).jsonl")
        try writeLines([
            #"{"timestamp":"2026-10-15T00:00:00Z","type":"session_meta","payload":{"id":"\#(id)","cwd":"/tmp/ccbar-fixture"}}"#,
            #"{"timestamp":"2026-10-15T00:00:00Z","type":"turn_context","payload":{"model":"gpt-6.1-sol"}}"#,
            codexItem(t0, type: "UserMessage", started: t0),
            codexItem(t0 + 3_000, type: "Reasoning", started: t0 + 1_000),
            #"{"timestamp":"\#(stamp(t0 + 10_000))","type":"inter_agent_communication_metadata","payload":{"trigger_turn":true}}"#,
            codexItem(t0 + 14_000, type: "Reasoning", started: t0 + 12_000),
            codexUsageRecord(t0 + 16_000, output: 300),
            codexTokenCount(t0 + 16_001, output: 300, total: 1_000),
        ], to: file)

        let result = await CodexJSONLScanner.scan(previous: [:], roots: [sessions], indexedTitles: [:])
        XCTAssertEqual(result.entries.first?.timing, RequestTiming(firstTokenMs: 2000, generationMs: 4000))
    }

    /// 缓存写入字段两种写法都认：`cache_write_tokens` 与 `cache_write_input_tokens`。
    func testCodexReadsCacheWriteInputTokens() async throws {
        let sessions = tempDir.appendingPathComponent("sessions", isDirectory: true)
        try FileManager.default.createDirectory(at: sessions, withIntermediateDirectories: true)
        let id = "66666666-6666-4666-8666-666666666666"
        let file = sessions.appendingPathComponent("rollout-2026-10-15T00-00-00-\(id).jsonl")
        try writeLines([
            #"{"timestamp":"2026-10-15T00:00:00Z","type":"session_meta","payload":{"id":"\#(id)","cwd":"/tmp/ccbar-fixture"}}"#,
            #"{"timestamp":"2026-10-15T00:00:00Z","type":"turn_context","payload":{"model":"gpt-6.1-sol"}}"#,
            #"{"timestamp":"2026-10-15T00:00:01Z","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":1000,"cached_input_tokens":200,"cache_write_input_tokens":300,"output_tokens":10,"total_tokens":1010},"last_token_usage":{"input_tokens":1000,"cached_input_tokens":200,"cache_write_input_tokens":300,"output_tokens":10,"total_tokens":1010}}}}"#,
        ], to: file)

        let result = await CodexJSONLScanner.scan(previous: [:], roots: [sessions], indexedTitles: [:])
        let entry = try XCTUnwrap(result.entries.first)
        XCTAssertEqual(entry.cacheCreationTokens, 300)
        XCTAssertEqual(entry.inputTokens, 500)
    }

    func testGenerationTimingThresholdsAndAverages() {
        var timing = GenerationTiming.zero
        timing.add(RequestTiming(firstTokenMs: 1000, generationMs: 2000), outputTokens: 200)
        timing.add(RequestTiming(firstTokenMs: 3000, generationMs: 400), outputTokens: 500)
        timing.add(RequestTiming(firstTokenMs: 2000, generationMs: 1000), outputTokens: 50)
        timing.add(nil, outputTokens: 1000)
        XCTAssertEqual(timing.firstTokenCount, 3, "首字延迟计入所有有首字时间的请求")
        XCTAssertEqual(timing.averageFirstTokenSeconds, 2.0)
        XCTAssertEqual(timing.timedOutputTokens, 200, "生成不足 0.5 秒或输出不足 100 tokens 的请求不计速度")
        XCTAssertEqual(timing.outputTokensPerSecond, 100)
        XCTAssertNil(GenerationTiming.zero.outputTokensPerSecond)

        XCTAssertNil(RequestTiming(requestStartMs: 1000, firstTokenMs: 900, endMs: 2000), "首字早于请求发出")
        XCTAssertNil(RequestTiming(requestStartMs: 0, firstTokenMs: 1000, endMs: 500), "结束早于首字")
        XCTAssertNil(RequestTiming(requestStartMs: 0, firstTokenMs: 11 * 60 * 1000, endMs: 11 * 60 * 1000))
    }

    /// 没有计时的桶不写 timing 键；旧快照没有这个键也能读出。
    func testTimingCodableIsOptional() throws {
        var bucket = UsageBucket(
            app: .claude, model: "claude-opus-5-5", speed: .standard, day: Date(timeIntervalSince1970: 0),
            inputTokens: 1, outputTokens: 2, cacheReadTokens: 0, cacheCreationTokens: 0,
            costUSD: 0, requestCount: 1, hasUnpricedUsage: false
        )
        let plain = try JSONEncoder().encode(bucket)
        XCTAssertFalse(String(decoding: plain, as: UTF8.self).contains("timing"))
        XCTAssertEqual(try JSONDecoder().decode(UsageBucket.self, from: plain).timing, .zero)

        bucket.timing.add(RequestTiming(firstTokenMs: 1500, generationMs: 3000), outputTokens: 300)
        let timed = try JSONDecoder().decode(UsageBucket.self, from: JSONEncoder().encode(bucket))
        XCTAssertEqual(timed.timing, bucket.timing)

        bucket.app = .pi
        bucket.timing = .zero
        bucket.timing.add(RequestTiming(generationMs: 3000.0), outputTokens: 600)
        let speedOnly = try JSONDecoder().decode(UsageBucket.self, from: JSONEncoder().encode(bucket))
        XCTAssertEqual(speedOnly.timing.outputTokensPerSecond, 200)
        XCTAssertNil(speedOnly.timing.averageFirstTokenSeconds)
    }

    func testSpeedOnlyTimingDoesNotChangeFirstTokenAverage() throws {
        let speedOnly = try XCTUnwrap(RequestTiming(generationMs: 3000.0))
        var timing = GenerationTiming.zero
        timing.add(speedOnly, outputTokens: 600)
        XCTAssertEqual(timing.outputTokensPerSecond, 200)
        XCTAssertEqual(timing.firstTokenCount, 0)
        XCTAssertNil(timing.averageFirstTokenSeconds)
        XCTAssertFalse(timing.isEmpty)

        var existing = GenerationTiming.zero
        existing.add(RequestTiming(firstTokenMs: 1500, generationMs: 2000), outputTokens: 400)
        existing.merge(timing)
        XCTAssertEqual(existing.averageFirstTokenSeconds, 1.5)
        XCTAssertEqual(existing.outputTokensPerSecond, 200)
        XCTAssertEqual(try JSONDecoder().decode(GenerationTiming.self, from: JSONEncoder().encode(timing)), timing)
        XCTAssertEqual(try JSONDecoder().decode(RequestTiming.self, from: JSONEncoder().encode(speedOnly)), speedOnly)
        let legacy = Data(#"{"firstTokenMs":1500,"generationMs":2000}"#.utf8)
        XCTAssertEqual(try JSONDecoder().decode(RequestTiming.self, from: legacy).firstTokenMs, 1500)

        XCTAssertNil(RequestTiming(generationMs: 0.0))
        XCTAssertNil(RequestTiming(generationMs: -1.0))
        XCTAssertNil(RequestTiming(generationMs: Double.infinity))
        XCTAssertNil(RequestTiming(generationMs: Double.nan))
        XCTAssertNil(RequestTiming(generationMs: RequestTiming.maxGenerationMs + 1))
    }

    func testUsageLogPathMatcherIgnoresUnrelatedWrites() {
        let home = URL(fileURLWithPath: "/Users/tester", isDirectory: true)
        let roots = UsageScanRoots(
            claudeRoot: home.appendingPathComponent(".claude/projects", isDirectory: true),
            claudeConversationIndex: { ConversationTitleIndex.ClaudeIndex(titles: [:], projects: [:]) },
            codexRoots: [
                home.appendingPathComponent(".codex/sessions", isDirectory: true),
                home.appendingPathComponent(".codex/archived_sessions", isDirectory: true),
            ],
            codexTitles: { [:] },
            piRoot: home.appendingPathComponent(".pi/agent/sessions", isDirectory: true),
            opencodeDatabaseURL: home.appendingPathComponent(".local/share/opencode/opencode.db"),
            dshRoot: home.appendingPathComponent(".dsh/sessions", isDirectory: true)
        )
        let matcher = UsageLogPathMatcher.standard(roots: roots)

        XCTAssertTrue(matcher.matches("/Users/tester/.claude/projects/-a/s.jsonl"))
        XCTAssertTrue(matcher.matches("/Users/tester/.codex/sessions"), "日志目录本身新建也算")
        XCTAssertTrue(matcher.matches("/Users/tester/.codex/archived_sessions/r.jsonl.zst"))
        XCTAssertTrue(matcher.matches("/Users/tester/.local/share/opencode/opencode.db-wal"))
        XCTAssertFalse(matcher.matches("/Users/tester/.local/share/opencode/opencode.db-shm"), "只读打开也会写 -shm")
        XCTAssertFalse(matcher.matches("/Users/tester/.claude/settings.json"))
        XCTAssertFalse(matcher.matches("/Users/tester/.claude/projects-old/x.jsonl"), "前缀须按路径段匹配")
        XCTAssertFalse(matcher.matches("/Users/tester/.codex/config.toml"))

        let enabledMatcher = UsageLogPathMatcher.standard(roots: roots, apps: [.codex])
        XCTAssertTrue(enabledMatcher.matches("/Users/tester/.codex/sessions/r.jsonl"))
        XCTAssertFalse(enabledMatcher.matches("/Users/tester/.claude/projects/-a/s.jsonl"))
        XCTAssertFalse(enabledMatcher.matches("/Users/tester/.local/share/opencode/opencode.db-wal"))

        let unrelated = "/Users/tester/.codex/config.toml"
        XCTAssertFalse(matcher.shouldMark(paths: [unrelated], flags: [0]))
        XCTAssertTrue(matcher.shouldMark(
            paths: [unrelated],
            flags: [FSEventStreamEventFlags(kFSEventStreamEventFlagMustScanSubDirs)]
        ), "事件被合并时无法确定路径，按有变化处理")
        XCTAssertTrue(matcher.shouldMark(paths: [unrelated], flags: []), "路径与标志数量不一致时保守放行")
    }
}

private extension ISO8601DateFormatter {
    static let ccbarTestFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()
}
