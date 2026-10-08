import XCTest
@testable import CCBar

/// 批次 C：QuotaPersistenceCoordinator 的串行写、pending 合并、乱序防护与失败不中断语义。
final class QuotaPersistenceCoordinatorTests: XCTestCase {
    private var tempDir: URL!

    override func setUpWithError() throws {
        let raw = FileManager.default.temporaryDirectory
            .appendingPathComponent("quota-coord-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: raw, withIntermediateDirectories: true)
        tempDir = raw.path.withCString { cpath in
            guard let resolved = realpath(cpath, nil) else { return raw }
            defer { free(resolved) }
            return URL(fileURLWithPath: String(cString: resolved), isDirectory: true)
        }
    }

    override func tearDownWithError() throws {
        if let tempDir {
            try? FileManager.default.removeItem(at: tempDir)
        }
    }

    /// 测试 writer：写 payload 文件 + 记录本次提交的 sequence（用于乱序断言）。
    private static func write(_ snapshot: QuotaPersistenceCoordinator.Snapshot, to dir: URL) throws {
        if let cache = snapshot.cache {
            try JSONEncoder().encode(cache).write(to: dir.appendingPathComponent("cache.json"), options: [.atomic])
        }
        if let history = snapshot.history {
            try JSONEncoder().encode(history).write(to: dir.appendingPathComponent("history.json"), options: [.atomic])
        }
        if let cycles = snapshot.cycles {
            try JSONEncoder().encode(cycles).write(to: dir.appendingPathComponent("cycles.json"), options: [.atomic])
        }
        try Data(String(snapshot.sequence).utf8).write(to: dir.appendingPathComponent("seq.txt"), options: [.atomic])
    }

    private func fileExists(_ name: String) -> Bool {
        FileManager.default.fileExists(atPath: tempDir.appendingPathComponent(name).path)
    }

    private func lastWrittenSequence() -> UInt64? {
        guard let data = try? Data(contentsOf: tempDir.appendingPathComponent("seq.txt")) else { return nil }
        return UInt64(String(data: data, encoding: .utf8) ?? "")
    }

    private func snapshot(sequence: UInt64, cache: Bool = false, history: Bool = false, cycles: Bool = false) -> QuotaPersistenceCoordinator.Snapshot {
        QuotaPersistenceCoordinator.Snapshot(
            sequence: sequence,
            cache: cache ? QuotaCachePayload() : nil,
            history: history ? QuotaHistoryPayload() : nil,
            cycles: cycles ? QuotaCyclePayload() : nil
        )
    }

    /// 顺序提交：同一文件以最后一次为准，不同文件互不影响。
    func testSequentialSubmitsWriteLatestPerFile() async {
        let coordinator = QuotaPersistenceCoordinator { snapshot in
            try Self.write(snapshot, to: self.tempDir)
        }
        await coordinator.submit(snapshot(sequence: 1, cache: true))
        await coordinator.submit(snapshot(sequence: 2, cache: true, history: true))
        await coordinator.submit(snapshot(sequence: 3, cycles: true))

        XCTAssertTrue(fileExists("cache.json"))
        XCTAssertTrue(fileExists("history.json"))
        XCTAssertTrue(fileExists("cycles.json"))
        XCTAssertEqual(lastWrittenSequence(), 3)
    }

    /// 乱序防护：旧 sequence 的提交即使后到也必须被丢弃（模拟两个 detached
    /// task 乱序到达 actor 的场景），最终落盘的是新 sequence 的内容。
    func testOutOfOrderSubmitKeepsNewest() async {
        let coordinator = QuotaPersistenceCoordinator { snapshot in
            try Self.write(snapshot, to: self.tempDir)
        }
        await coordinator.submit(snapshot(sequence: 2, cache: true))
        await coordinator.submit(snapshot(sequence: 1, cache: true))

        XCTAssertEqual(lastWrittenSequence(), 2, "旧序列号的提交不应覆盖新快照")
        XCTAssertTrue(fileExists("cache.json"))
    }

    /// 后续提交只携带部分文件时，pending 中尚未写入的文件不能被挤掉
    /// （串行或写入期间合并两种时序下都成立）。
    func testPendingMergeKeepsFilesNotInNewSnapshot() async {
        let coordinator = QuotaPersistenceCoordinator { snapshot in
            try Self.write(snapshot, to: self.tempDir)
        }
        // 先提交 history，紧随其后（写入期间）提交 cache——history 不能被新提交挤掉。
        await coordinator.submit(snapshot(sequence: 1, history: true))
        await coordinator.submit(snapshot(sequence: 2, cache: true))

        XCTAssertTrue(fileExists("history.json"), "pending 中尚未写入的文件应被合并保留")
        XCTAssertTrue(fileExists("cache.json"))
        XCTAssertEqual(lastWrittenSequence(), 2)
    }

    /// 并发提交：所有提交都会到达 actor，最终落盘必须是最大的 sequence。
    func testConcurrentSubmitsEndWithLatestSequence() async {
        let coordinator = QuotaPersistenceCoordinator { snapshot in
            try Self.write(snapshot, to: self.tempDir)
        }
        await withTaskGroup(of: Void.self) { group in
            for i in 1...10 {
                group.addTask {
                    await coordinator.submit(self.snapshot(sequence: UInt64(i), cache: true))
                }
            }
        }
        // 10 号提交必然到达 actor；无论到达顺序如何，guard 保证它最终胜出。
        XCTAssertEqual(lastWrittenSequence(), 10)
        let data = try? Data(contentsOf: tempDir.appendingPathComponent("cache.json"))
        let decoded = data.flatMap { try? JSONDecoder().decode(QuotaCachePayload.self, from: $0) }
        XCTAssertNotNil(decoded, "最终写入的文件必须完整可解码")
    }

    /// 写入失败只记录日志，不能阻断后续提交。
    func testWriterFailureDoesNotBlockNextSubmit() async {
        let counter = Counter()
        let coordinator = QuotaPersistenceCoordinator { snapshot in
            let n = counter.increment()
            if n == 1 {
                throw CocoaError(.fileWriteUnknown)
            }
            try Self.write(snapshot, to: self.tempDir)
        }
        await coordinator.submit(snapshot(sequence: 1, cache: true))
        await coordinator.submit(snapshot(sequence: 2, history: true))

        XCTAssertFalse(fileExists("cache.json"), "首次写入失败不应落盘")
        XCTAssertTrue(fileExists("history.json"), "失败后后续提交应继续执行")
        XCTAssertEqual(lastWrittenSequence(), 2, "失败的提交不应推进已写入序列号")
        XCTAssertEqual(counter.value, 2)
    }

    /// 全 nil 快照（AppState 层不应产生）无害：不产生任何文件。
    func testEmptySnapshotIsNoOp() async {
        let coordinator = QuotaPersistenceCoordinator { snapshot in
            try Self.write(snapshot, to: self.tempDir)
        }
        await coordinator.submit(snapshot(sequence: 1))
        XCTAssertFalse(fileExists("cache.json"))
        XCTAssertFalse(fileExists("history.json"))
        XCTAssertFalse(fileExists("cycles.json"))
    }

    func testTerminationSaveReportsFailureAndCanRetrySameSequence() async throws {
        let counter = Counter()
        let coordinator = QuotaPersistenceCoordinator { snapshot in
            if counter.increment() == 1 { throw CocoaError(.fileWriteUnknown) }
            try Self.write(snapshot, to: self.tempDir)
        }
        let final = snapshot(sequence: 2, cache: true, history: true, cycles: true)
        do {
            try await coordinator.persistForTermination(final)
            XCTFail("退出保存失败必须返回错误，不能允许退出")
        } catch {
            XCTAssertEqual((error as? CocoaError)?.code, .fileWriteUnknown)
        }
        try await coordinator.persistForTermination(final)
        await coordinator.submit(snapshot(sequence: 1, cache: true))
        XCTAssertEqual(lastWrittenSequence(), 2)
        XCTAssertTrue(fileExists("cache.json"))
        XCTAssertTrue(fileExists("history.json"))
        XCTAssertTrue(fileExists("cycles.json"))
        XCTAssertEqual(counter.value, 2, "保存成功后较旧的排队写入不能再覆盖最终状态")
    }
}

/// 线程安全的调用计数器（测试辅助）。
private final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    func increment() -> Int {
        lock.lock()
        defer { lock.unlock() }
        count += 1
        return count
    }

    var value: Int {
        lock.lock()
        defer { lock.unlock() }
        return count
    }
}
