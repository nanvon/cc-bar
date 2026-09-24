import XCTest
@testable import CCBar

/// DSH 会话日志的帧扫描与单帧解码测试。
///
/// 依据：`docs/草案-DSH本地用量-技术方案.md` §3.1（帧处理）、§7 S1（验证）、§8（覆盖清单）。
/// fixture 全部由工程链接的 libzstd 现场编码——不依赖本机 `zstd` 命令，也不依赖外部样本文件；
/// 基准值来自文件长度、拼接前缀和与原始明文，不是被测代码自身的推算。
final class DshZstdFrameScannerTests: XCTestCase {
    private let plainA = Data("hello dsh frame".utf8)
    private let plainB = Data("second frame payload, a bit longer than the first one".utf8)
    private let plainC = Data("third".utf8)
    /// 400 KB 明文会跨多个 zstd block，但仍是**一个**帧。
    private let plainBig = Data(repeating: 0x41, count: 400_000)

    // MARK: - fixture 编码

    /// 帧编码统一走 `DshTestFixtures`（与 DshSessionScannerTests 共用，避免两套 C API 胶水）。
    private func makeFrame(_ payload: Data, checksum: Bool = true) throws -> Data {
        try DshTestFixtures.frame(payload, checksum: checksum)
    }

    private func makeStreamingFrame(_ payload: Data, checksum: Bool = true) throws -> Data {
        try DshTestFixtures.streamingFrame(payload, checksum: checksum)
    }

    private func frames(_ data: Data, maxFrames: Int = .max) throws -> DshZstdFrames.ScanResult {
        guard case .scanned(let result) = DshZstdFrames.scan(data, maxFrames: maxFrames) else {
            throw XCTSkip("期望扫描成功，实际判定为损坏")
        }
        return result
    }

    private func corruption(_ data: Data) -> DshZstdFrames.Corruption? {
        guard case .corrupt(let corruption) = DshZstdFrames.scan(data) else { return nil }
        return corruption
    }

    private func decoded(_ frame: Data, outputLimit: Int = DshZstdDecoder.defaultOutputLimit) throws -> Data {
        try DshZstdDecoder.decodeFrame(frame, outputLimit: outputLimit)
    }

    // MARK: - 帧边界

    func testSingleFrameCoversWholeFile() throws {
        let frame = try makeFrame(plainA)
        let result = try frames(frame)
        XCTAssertEqual(result.frames.map(\.start), [0])
        XCTAssertEqual(result.frames.map(\.end), [frame.count])
        XCTAssertNil(result.tornStart)
        XCTAssertEqual(DshZstdFrames.consumedByteCount(.scanned(result)), frame.count)
    }

    func testConcatenatedFramesUsePrefixSumsAsBoundaries() throws {
        // 三个独立帧的拼接：边界必然等于各帧长度前缀和
        let first = try makeFrame(plainA)
        let second = try makeFrame(plainB)
        let third = try makeFrame(plainC)
        let concatenated = first + second + third

        let result = try frames(concatenated)
        XCTAssertEqual(
            result.frames.map(\.start),
            [0, first.count, first.count + second.count]
        )
        XCTAssertEqual(
            result.frames.map(\.end),
            [first.count, first.count + second.count, concatenated.count]
        )
        XCTAssertNil(result.tornStart)
    }

    func testMultiBlockFrameIsStillOneFrame() throws {
        let frame = try makeFrame(plainBig)
        let result = try frames(frame)
        XCTAssertEqual(result.frames.count, 1)
        XCTAssertEqual(result.frames.first?.length, frame.count)
    }

    func testStreamingFrameWithWindowDescriptorIsScanned() throws {
        // single segment 位为 0 时帧头多一个 window descriptor 字节，长度算法不同
        let frame = try makeStreamingFrame(plainB)
        XCTAssertEqual(frame[frame.startIndex + 4] & 32, 0, "fixture 应是不带 content size 的流式帧头")
        let result = try frames(frame)
        XCTAssertEqual(result.frames.map(\.length), [frame.count])
    }

    func testFrameWithoutChecksumIsFourBytesShorter() throws {
        let withChecksum = try makeFrame(plainA, checksum: true)
        let withoutChecksum = try makeFrame(plainA, checksum: false)
        XCTAssertEqual(withChecksum.count - withoutChecksum.count, 4)
        XCTAssertEqual(try frames(withoutChecksum).frames.map(\.length), [withoutChecksum.count])
    }

    func testTornTailIsNotConsumedUntilBytesArrive() throws {
        let first = try makeFrame(plainA)
        let second = try makeFrame(plainB)
        let third = try makeFrame(plainC)
        let full = first + second + third

        // 砍掉第 3 帧的末尾 5 字节
        let torn = full.prefix(full.count - 5)
        let tornResult = try frames(Data(torn))
        XCTAssertEqual(tornResult.frames.map(\.end), [first.count, first.count + second.count])
        XCTAssertEqual(tornResult.tornStart, first.count + second.count)
        XCTAssertEqual(
            DshZstdFrames.consumedByteCount(.scanned(tornResult)),
            first.count + second.count,
            "撕裂尾帧不得推进消费偏移"
        )

        // 补齐后从 tornStart 续扫，尾部这一帧正常入账
        let tailStart = try XCTUnwrap(tornResult.tornStart)
        var repaired = Data(torn.suffix(from: torn.startIndex + tailStart))
        repaired.append(full.suffix(5))
        let repairedResult = try frames(repaired)
        XCTAssertEqual(repairedResult.frames.map(\.length), [third.count])
        XCTAssertNil(repairedResult.tornStart)
    }

    func testPartialHeaderIsTornNotCorrupt() throws {
        let frame = try makeFrame(plainA)
        let outcome = DshZstdFrames.scan(frame.prefix(6))
        guard case .scanned(let result) = outcome else {
            return XCTFail("帧头不完整属于撕裂，不是损坏")
        }
        XCTAssertTrue(result.frames.isEmpty)
        XCTAssertEqual(result.tornStart, 0)
    }

    func testMaxFramesReadsSessionHeaderOnly() throws {
        let first = try makeFrame(plainA)
        let concatenated = first + (try makeFrame(plainB)) + (try makeFrame(plainC))
        let result = try frames(concatenated, maxFrames: 1)
        XCTAssertEqual(result.frames.map(\.length), [first.count])
        XCTAssertNil(result.tornStart)
    }

    // MARK: - 损坏判定

    func testInvalidMagicIsCorrupt() throws {
        var damaged = try makeFrame(plainA)
        damaged[damaged.startIndex] = 0x00
        XCTAssertEqual(corruption(damaged), .invalidMagic(byteOffset: 0))
        XCTAssertEqual(DshZstdFrames.consumedByteCount(.corrupt(.invalidMagic(byteOffset: 0))), 0)
    }

    func testReservedFrameHeaderBitIsCorrupt() throws {
        var damaged = try makeFrame(plainA)
        damaged[damaged.startIndex + 4] |= 0x08
        XCTAssertEqual(corruption(damaged), .reservedFrameHeaderBit(byteOffset: 4))
    }

    func testReservedBlockTypeIsCorrupt() throws {
        var damaged = try makeFrame(plainA)
        // single segment 帧头 = magic(4) + descriptor(1) + content size(1)，block header 落在偏移 6
        XCTAssertEqual(damaged[damaged.startIndex + 4], 0x24, "fixture 帧头形态变化，偏移需重新确认")
        damaged[damaged.startIndex + 6] = 0x06 // blockType=(header>>1)&3 == 3 是保留类型
        XCTAssertEqual(corruption(damaged), .reservedBlockType(byteOffset: 6))
    }

    // MARK: - 单帧解码

    func testDecodeReturnsOriginalPayload() throws {
        let concatenated = try makeFrame(plainA) + (try makeFrame(plainB)) + (try makeFrame(plainC))
        let result = try frames(concatenated)
        let payloads = try result.frames.map { try decoded(concatenated.subdata(in: $0.start..<$0.end)) }
        XCTAssertEqual(payloads, [plainA, plainB, plainC])
    }

    func testDecodeMultiBlockFrame() throws {
        let frame = try makeFrame(plainBig)
        XCTAssertEqual(try decoded(frame), plainBig)
    }

    func testDecodeRejectsCorruptedChecksum() throws {
        var damaged = try makeFrame(plainA)
        damaged[damaged.endIndex - 1] ^= 0xFF
        // 扫描器不看 checksum，帧边界照旧
        XCTAssertEqual(try frames(damaged).frames.map(\.length), [damaged.count])
        XCTAssertThrowsError(try decoded(damaged)) { error in
            guard case .corruptedFrame = error as? DshZstdDecoder.DecodeError else {
                return XCTFail("checksum 不匹配应由 libzstd 报告 corruptedFrame，实际 \(error)")
            }
        }
    }

    func testDecodeRejectsTornFrame() throws {
        let frame = try makeFrame(plainA)
        XCTAssertThrowsError(try decoded(frame.dropLast(5))) { error in
            guard case .invalidFrame = error as? DshZstdDecoder.DecodeError else {
                return XCTFail("半截帧应被拒，实际 \(error)")
            }
        }
    }

    func testDecodeRejectsConcatenatedFrames() throws {
        let concatenated = try makeFrame(plainA) + (try makeFrame(plainB))
        XCTAssertThrowsError(try decoded(concatenated)) { error in
            guard case .invalidFrame = error as? DshZstdDecoder.DecodeError else {
                return XCTFail("多帧拼接必须逐帧传入，实际 \(error)")
            }
        }
    }

    func testDecodeEnforcesOutputLimit() throws {
        let frame = try makeFrame(plainBig)
        XCTAssertThrowsError(try decoded(frame, outputLimit: 1024)) { error in
            guard case .outputTooLarge = error as? DshZstdDecoder.DecodeError else {
                return XCTFail("超出输出上限应抛 outputTooLarge，实际 \(error)")
            }
        }
    }
}
