import Foundation
import libzstd

/// DSH 会话日志的单帧解码：只接受**一个完整帧**，拒绝多帧拼接与半截帧。
///
/// 职责边界（草案 §3.1）：
/// - 帧边界由 `DshZstdFrames` 负责，本类型不做边界扫描；
/// - checksum 由 libzstd 在解码时校验，本类型不重复实现；
/// - 输出按块收集并强制上限，避免损坏文件造成无界分配。
nonisolated enum DshZstdDecoder {
    /// 单帧解压输出上限（256 MiB）。正常会话帧远小于此值，触顶即视为损坏。
    static let defaultOutputLimit = 256 * 1024 * 1024

    /// 每次 `ZSTD_decompressStream` 的输出块大小。
    private static let outputChunkCapacity = 256 * 1024

    enum DecodeError: Error, Equatable, Sendable {
        /// 输入不是一个完整的 zstd 帧（长度与帧内声明不符，或不是帧）。
        case invalidFrame(expectedBytes: Int, actualBytes: Int)
        /// 输入在帧结束前耗尽。
        case truncatedInput
        /// libzstd 报告解码失败：损坏、checksum 不匹配等。`name` 是 libzstd 的错误名。
        case corruptedFrame(name: String)
        /// 解压输出超过上限。
        case outputTooLarge(limit: Int)
    }

    /// 解码一个完整帧，返回解压后的字节。
    ///
    /// - Parameters:
    ///   - frame: 恰好一个完整帧的字节（`DshZstdFrames.FrameRange` 对应的切片）。
    ///   - outputLimit: 解压输出上限，触顶抛 `outputTooLarge`。
    static func decodeFrame(
        _ frame: Data,
        outputLimit: Int = defaultOutputLimit
    ) throws -> Data {
        let inputSize = frame.count
        guard inputSize >= 4 else {
            throw DecodeError.invalidFrame(expectedBytes: 4, actualBytes: inputSize)
        }

        // 输入拷进自有缓冲区：下面的 C API 需要稳定的可变指针，且避免跨闭包传递 inout。
        let inputBuffer = UnsafeMutableRawPointer.allocate(byteCount: inputSize, alignment: 1)
        defer { inputBuffer.deallocate() }
        frame.withUnsafeBytes { source in
            if let base = source.baseAddress {
                inputBuffer.copyMemory(from: base, byteCount: inputSize)
            }
        }

        // 交叉校验：帧内声明的压缩长度必须与传入字节数一致，多帧拼接/半截帧在这里被拒。
        let declaredSize = ZSTD_findFrameCompressedSize(inputBuffer, inputSize)
        guard ZSTD_isError(declaredSize) == 0 else {
            throw DecodeError.invalidFrame(
                expectedBytes: 0,
                actualBytes: inputSize
            )
        }
        let declaredBytes = Int(declaredSize)
        guard declaredBytes == inputSize else {
            throw DecodeError.invalidFrame(expectedBytes: declaredBytes, actualBytes: inputSize)
        }

        guard let context = ZSTD_createDCtx() else {
            throw DecodeError.corruptedFrame(name: "ZSTD_createDCtx")
        }
        defer { ZSTD_freeDCtx(context) }

        let outputBuffer = UnsafeMutableRawPointer.allocate(
            byteCount: outputChunkCapacity,
            alignment: 1
        )
        defer { outputBuffer.deallocate() }

        var input = ZSTD_inBuffer(src: inputBuffer, size: inputSize, pos: 0)
        var output = Data()
        output.reserveCapacity(min(inputSize * 4, 1 << 20))

        while true {
            var chunk = ZSTD_outBuffer(dst: outputBuffer, size: outputChunkCapacity, pos: 0)
            let remaining = ZSTD_decompressStream(context, &chunk, &input)

            if ZSTD_isError(remaining) != 0 {
                throw DecodeError.corruptedFrame(name: String(cString: ZSTD_getErrorName(remaining)))
            }
            if chunk.pos > 0 {
                output.append(outputBuffer.assumingMemoryBound(to: UInt8.self), count: chunk.pos)
                if output.count > outputLimit {
                    throw DecodeError.outputTooLarge(limit: outputLimit)
                }
            }

            if remaining == 0 {
                // 帧结束：输入必须正好用完（多帧拼接由调用方按帧切分后逐帧传入）
                guard input.pos == input.size else {
                    throw DecodeError.invalidFrame(
                        expectedBytes: Int(input.pos),
                        actualBytes: input.size
                    )
                }
                return output
            }

            // 还有未完成帧，但输入已耗尽 → 半截帧
            if input.pos == input.size && chunk.pos == 0 {
                throw DecodeError.truncatedInput
            }
        }
    }
}
