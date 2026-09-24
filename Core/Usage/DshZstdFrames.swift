import Foundation

/// DSH 会话日志是「多帧拼接」的 zstd 容器：一个文件里顺序排列若干个互不依赖的完整帧。
/// 本类型只做**帧边界扫描**，不解压，用于在增量扫描中确定「哪些字节已经可以安全入账」。
///
/// 规则逐条对应 DSH 随包 `@deepseek-ai/dsh-session-persistence-jsonl` 的 `scanZstdFrames()`：
/// magic → frame header descriptor（保留位、FCS、single segment、checksum、字典）→ 逐块 block header
/// → 可选 4 字节 checksum。**这里不校验 checksum**，checksum 由 libzstd 在解码时校验（见 `DshZstdDecoder`）。
///
/// 偏移语义：所有偏移都相对传入 `Data` 的起点，因此调用方必须让缓冲区**从某个帧的起点开始**
/// （首扫传整个文件；增量扫描传「上一轮未完成帧的起点」到文件末尾），否则会误报 `invalidMagic`。
///
/// 草案依据：`docs/草案-DSH本地用量-技术方案.md` §3.1、§3.2。
nonisolated enum DshZstdFrames {
    /// zstd 帧 magic（小端字节序 `28 B5 2F FD`）。
    static let magic: UInt32 = 0xFD2F_B528

    /// 一个完整帧的字节范围，`end` 为开区间。
    struct FrameRange: Equatable, Sendable {
        let start: Int
        let end: Int

        var length: Int { end - start }
    }

    /// 损坏位置与原因。损坏时**整份扫描结果作废**：调用方丢弃该文件本轮结果并保留旧 watermark，
    /// 既不推进偏移也不入账，避免把坏文件的中段当成新数据（§3.2）。
    enum Corruption: Equatable, Sendable {
        case invalidMagic(byteOffset: Int)
        case reservedFrameHeaderBit(byteOffset: Int)
        case reservedBlockType(byteOffset: Int)
    }

    /// 一次扫描的结果。`tornStart` 是尾部未完成帧的起点：**正常撕裂不算失败**，
    /// 本轮不消费它，等字节补齐后从该偏移重扫。
    struct ScanResult: Equatable, Sendable {
        var frames: [FrameRange]
        /// 有值表示尾部还有未完成帧；nil 表示缓冲区正好结束在帧边界上。
        var tornStart: Int?
    }

    enum ScanOutcome: Equatable, Sendable {
        case scanned(ScanResult)
        case corrupt(Corruption)
    }

    /// 扫描缓冲区里所有完整帧。
    ///
    /// - Parameters:
    ///   - data: 从帧起点开始的字节缓冲区。
    ///   - maxFrames: 只取前 N 个完整帧（读会话头元数据时用），默认不限。
    static func scan(_ data: Data, maxFrames: Int = .max) -> ScanOutcome {
        var frames: [FrameRange] = []
        var offset = 0
        let total = data.count

        while offset < total {
            let start = offset

            // magic（4 字节）
            guard total - offset >= 4 else {
                return .scanned(ScanResult(frames: frames, tornStart: start))
            }
            guard readUInt32LE(data, at: offset) == magic else {
                return .corrupt(.invalidMagic(byteOffset: offset))
            }
            offset += 4

            // frame header descriptor（1 字节）；长度不够属于撕裂，不是损坏
            guard offset != total else {
                return .scanned(ScanResult(frames: frames, tornStart: start))
            }
            let descriptor = data[data.startIndex + offset]
            offset += 1

            // bit3/bit4 是保留位，必须为 0
            guard descriptor & 24 == 0 else {
                return .corrupt(.reservedFrameHeaderBit(byteOffset: offset - 1))
            }

            let contentSizeFlag = Int(descriptor >> 6)
            let singleSegment = descriptor & 32 != 0
            let checksum = descriptor & 4 != 0
            let dictionaryFlag = Int(descriptor & 3)
            let dictionaryBytes = dictionaryFlag == 3 ? 4 : dictionaryFlag
            let contentSizeBytes = contentSizeFlag == 0 ? (singleSegment ? 1 : 0) : 1 << contentSizeFlag
            // 非 single segment 时多一个 window descriptor 字节
            let remainingHeaderBytes = (singleSegment ? 0 : 1) + dictionaryBytes + contentSizeBytes

            guard total - offset >= remainingHeaderBytes else {
                return .scanned(ScanResult(frames: frames, tornStart: start))
            }
            offset += remainingHeaderBytes

            // 逐块扫描，直到 last block
            while true {
                guard total - offset >= 3 else {
                    return .scanned(ScanResult(frames: frames, tornStart: start))
                }
                let blockHeader = readUInt24LE(data, at: offset)
                offset += 3

                let lastBlock = blockHeader & 1 != 0
                let blockType = (blockHeader >> 1) & 3
                let blockSize = blockHeader >> 3

                guard blockType != 3 else {
                    return .corrupt(.reservedBlockType(byteOffset: offset - 3))
                }
                // RLE 块的 payload 恒为 1 字节，其余按 blockSize
                let payloadBytes = blockType == 1 ? 1 : blockSize
                guard total - offset >= payloadBytes else {
                    return .scanned(ScanResult(frames: frames, tornStart: start))
                }
                offset += payloadBytes

                if lastBlock { break }
            }

            // 可选 4 字节 content checksum
            if checksum {
                guard total - offset >= 4 else {
                    return .scanned(ScanResult(frames: frames, tornStart: start))
                }
                offset += 4
            }

            frames.append(FrameRange(start: start, end: offset))
            if frames.count == maxFrames {
                return .scanned(ScanResult(frames: frames, tornStart: nil))
            }
        }

        return .scanned(ScanResult(frames: frames, tornStart: nil))
    }

    /// 缓冲区里「已经完整、可以消费」的字节数：最后一个完整帧的末尾。
    /// 撕裂尾帧与损坏都不会让它前进。
    static func consumedByteCount(_ outcome: ScanOutcome) -> Int {
        switch outcome {
        case .scanned(let result):
            return result.frames.last?.end ?? 0
        case .corrupt:
            return 0
        }
    }

    // MARK: - 字节读取

    private static func readUInt32LE(_ data: Data, at offset: Int) -> UInt32 {
        let base = data.startIndex + offset
        return UInt32(data[base])
            | UInt32(data[base + 1]) << 8
            | UInt32(data[base + 2]) << 16
            | UInt32(data[base + 3]) << 24
    }

    private static func readUInt24LE(_ data: Data, at offset: Int) -> Int {
        let base = data.startIndex + offset
        return Int(data[base])
            | Int(data[base + 1]) << 8
            | Int(data[base + 2]) << 16
    }
}
