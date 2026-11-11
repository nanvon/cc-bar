import XCTest
@testable import CCBar

/// `AtomicWriteLeftoverCleaner` 只删过期的原子写临时文件，其他文件一律不动。
///
/// 全部在临时目录里跑：不读也不写用户真实的 `~/Library/Application Support/CCBar`。
final class AtomicWriteLeftoverCleanerTests: XCTestCase {
    private var tempDir: URL!
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    override func setUpWithError() throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("atomic-write-cleaner-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let tempDir {
            try? FileManager.default.removeItem(at: tempDir)
        }
    }

    @discardableResult
    private func makeFile(_ name: String, in directory: URL? = nil, ageHours: Double) throws -> URL {
        let url = (directory ?? tempDir).appendingPathComponent(name)
        try Data("x".utf8).write(to: url)
        let modified = now.addingTimeInterval(-ageHours * 3600)
        try FileManager.default.setAttributes([.modificationDate: modified], ofItemAtPath: url.path)
        return url
    }

    private func exists(_ url: URL) -> Bool {
        FileManager.default.fileExists(atPath: url.path)
    }

    func testLeftoverNamePattern() {
        XCTAssertTrue(AtomicWriteLeftoverCleaner.isLeftoverName("quota-cache.json.sb-1f3dd933-kAvjpC"))
        XCTAssertTrue(AtomicWriteLeftoverCleaner.isLeftoverName("usage-rollup.json.sb-c162f3ce-ePKPcz"))

        XCTAssertFalse(AtomicWriteLeftoverCleaner.isLeftoverName("quota-cache.json"))
        XCTAssertFalse(AtomicWriteLeftoverCleaner.isLeftoverName("quota-cycle-history.json.bak-20260817-144424"))
        XCTAssertFalse(AtomicWriteLeftoverCleaner.isLeftoverName(".sb-1f3dd933-kAvjpC"))
        XCTAssertFalse(AtomicWriteLeftoverCleaner.isLeftoverName("a.json.sb-1f3dd93-kAvjpC"))
        XCTAssertFalse(AtomicWriteLeftoverCleaner.isLeftoverName("a.json.sb-1f3dd93z-kAvjpC"))
        XCTAssertFalse(AtomicWriteLeftoverCleaner.isLeftoverName("a.json.sb-1f3dd933-kAvjp"))
        XCTAssertFalse(AtomicWriteLeftoverCleaner.isLeftoverName("a.json.sb-1f3dd933-kAvjpC-x"))
        XCTAssertFalse(AtomicWriteLeftoverCleaner.isLeftoverName("a.json.sb-1f3dd933-kAv.pC"))
    }

    func testRemovesOnlyStaleLeftovers() throws {
        let stale = try makeFile("quota-cache.json.sb-1f3dd933-kAvjpC", ageHours: 48)
        let fresh = try makeFile("quota-cache.json.sb-4080b1f7-8J67wL", ageHours: 1)
        let target = try makeFile("quota-cache.json", ageHours: 48)
        let backup = try makeFile("quota-cycle-history.json.bak-20260817-144424", ageHours: 48)
        let imported = try makeFile("imported-usage-claude-2026H1-gapfill.json", ageHours: 48)

        let removed = AtomicWriteLeftoverCleaner.removeStaleLeftovers(in: [tempDir], now: now)

        XCTAssertEqual(removed.map(\.lastPathComponent), [stale.lastPathComponent])
        XCTAssertFalse(exists(stale))
        XCTAssertTrue(exists(fresh))
        XCTAssertTrue(exists(target))
        XCTAssertTrue(exists(backup))
        XCTAssertTrue(exists(imported))
    }

    func testDoesNotRecurseOrTouchDirectories() throws {
        let quarantine = tempDir.appendingPathComponent("quarantine", isDirectory: true)
        try FileManager.default.createDirectory(at: quarantine, withIntermediateDirectories: true)
        let nested = try makeFile("current.json.sb-1f3dd933-kAvjpC", in: quarantine, ageHours: 48)

        let directoryLookalike = tempDir.appendingPathComponent("x.json.sb-1f3dd933-kAvjpC", isDirectory: true)
        try FileManager.default.createDirectory(at: directoryLookalike, withIntermediateDirectories: true)
        try FileManager.default.setAttributes(
            [.modificationDate: now.addingTimeInterval(-48 * 3600)],
            ofItemAtPath: directoryLookalike.path
        )

        let removed = AtomicWriteLeftoverCleaner.removeStaleLeftovers(in: [tempDir], now: now)

        XCTAssertTrue(removed.isEmpty)
        XCTAssertTrue(exists(nested))
        XCTAssertTrue(exists(directoryLookalike))
    }

    func testMissingDirectoryIsIgnored() {
        let missing = tempDir.appendingPathComponent("missing", isDirectory: true)
        XCTAssertTrue(AtomicWriteLeftoverCleaner.removeStaleLeftovers(in: [missing], now: now).isEmpty)
    }
}
