import Foundation

/// 从指定字节偏移开始按行读取一个文件。
/// 扫描器走 `streamLines`：按块读入、按整行切批回调，单文件常驻内存与文件大小无关；
/// `readOutcome` / `read` 保留给只关心"一次拿到全部行"的调用方与单测。
enum JSONLLineReader {
    enum ReadOutcome: Sendable {
        case success(lines: [String], newOffset: UInt64)
        /// 文件在枚举后、真正读取前被移动或删除；这是正常并发变化，不是扫描失败。
        case missing
        case failed
    }

    /// `streamLines` 的结果；行本身已通过回调交付，这里只回报新的 watermark。
    enum StreamOutcome: Sendable {
        case success(newOffset: UInt64)
        case missing
        case failed
    }

    /// 单次读盘的块大小。块内按整行切分，跨块的残行留到下一块拼接。
    nonisolated static let defaultChunkSize = 4 << 20

    /// 单批回调的最大行数。批越小，每批 JSON 解析产生的 autorelease 对象越早释放。
    nonisolated static let defaultBatchLines = 256

    /// 分块流式读取：从 `offset` 起按整行交付，`onBatch` 每批最多 `defaultBatchLines` 行。
    /// 消费语义与 `readOutcome` 完全一致——只消费到最后一个 `\n`，
    /// 末尾未结束的残行不推进 offset，整段没有换行时 `newOffset == offset`。
    /// 每批回调都包在 `autoreleasepool` 里：调用方逐行 `JSONSerialization` 产生的
    /// Objective-C 临时对象在长任务中不会一直挂在线程池里，这是全量重扫内存峰值的主因。
    /// `.jsonl.zst` 透明解压，offset 按解压后的字节计。
    nonisolated static func streamLines(
        url: URL,
        fromOffset offset: UInt64,
        throughOffset: UInt64? = nil,
        chunkSize: Int = defaultChunkSize,
        batchLines: Int = defaultBatchLines,
        onBatch: (ArraySlice<String>) -> Void
    ) -> StreamOutcome {
        if JSONLDirectoryEnumerator.isZstd(url) {
            return streamZstdLines(url: url, fromOffset: offset, throughOffset: throughOffset,
                                   chunkSize: chunkSize, batchLines: batchLines, onBatch: onBatch)
        }
        guard let handle = try? FileHandle(forReadingFrom: url) else {
            return failureStreamOutcome(for: url)
        }
        defer { try? handle.close() }

        let end: UInt64
        do {
            end = try handle.seekToEnd()
        } catch {
            return failureStreamOutcome(for: url)
        }
        // 历史标识迁移只能读取已提交 watermark 以内的完整行。文件比边界短、坏 UTF-8、
        // 边界不在行尾都是内容层面的确定结果：以短于边界的 offset 返回，由调用方判为不可验证；
        // `.failed` / `.missing` 只留给打开、读取失败和文件被移走这类可重试的情况。
        if let throughOffset, end < throughOffset { return .success(newOffset: offset) }
        if offset >= end {
            return .success(newOffset: end)
        }
        do {
            try handle.seek(toOffset: offset)
        } catch {
            return failureStreamOutcome(for: url)
        }
        return streamChunks(url: url, fromOffset: offset, throughOffset: throughOffset,
                            chunkSize: chunkSize, batchLines: batchLines, onBatch: onBatch) { count in
            try handle.read(upToCount: count)
        }
    }

    /// 压缩日志：先解压跳过已消费的 offset，再按与明文相同的整行规则交付。
    /// 内容比 offset 短时返回实际长度，由调用方按截断处理。
    nonisolated private static func streamZstdLines(
        url: URL,
        fromOffset offset: UInt64,
        throughOffset: UInt64?,
        chunkSize: Int,
        batchLines: Int,
        onBatch: (ArraySlice<String>) -> Void
    ) -> StreamOutcome {
        guard let reader = try? ZstdStreamReader(url: url) else {
            return failureStreamOutcome(for: url)
        }
        let skipped: UInt64
        do {
            skipped = try reader.skip(offset)
        } catch {
            return failureStreamOutcome(for: url)
        }
        if skipped < offset { return .success(newOffset: skipped) }
        return streamChunks(url: url, fromOffset: offset, throughOffset: throughOffset,
                            chunkSize: chunkSize, batchLines: batchLines, onBatch: onBatch) { count in
            try reader.read(upToCount: count)
        }
    }

    /// 从 `offset` 处起按块读入、按整行交付；`readChunk` 返回 nil 或空块表示到头。
    nonisolated private static func streamChunks(
        url: URL,
        fromOffset offset: UInt64,
        throughOffset: UInt64?,
        chunkSize: Int,
        batchLines: Int,
        onBatch: (ArraySlice<String>) -> Void,
        readChunk: (Int) throws -> Data?
    ) -> StreamOutcome {
        let newline = UInt8(ascii: "\n")
        var pending = Data()
        var consumed: UInt64 = 0
        var bytesRead = offset
        // 整块处理都包在池里：`FileHandle.read` 每块返回的是 autoreleased NSData 支撑的
        // Data，只包住解析回调的话这些块会一直挂到任务结束，长任务照样吃满内存。
        while true {
            var finished = false
            var failure: StreamOutcome?
            autoreleasepool {
                let chunk: Data?
                do {
                    if let throughOffset, bytesRead >= throughOffset {
                        finished = true
                        return
                    }
                    let count = throughOffset.map { Int(min(UInt64(chunkSize), $0 - bytesRead)) } ?? chunkSize
                    chunk = try readChunk(count)
                } catch {
                    failure = failureStreamOutcome(for: url)
                    return
                }
                guard let chunk, !chunk.isEmpty else {
                    finished = true
                    return
                }
                bytesRead += UInt64(chunk.count)
                let appendedStart = pending.endIndex
                pending.append(chunk)
                // 单行长于块大小时本块没有换行，继续累积到出现换行为止；
                // 已确认无换行的前缀不再重复扫描，超长行不会退化成平方级。
                guard let lastNewline = pending[appendedStart...].lastIndex(of: newline) else { return }
                let completeEnd = pending.index(after: lastNewline)
                let completePart = pending.subdata(in: pending.startIndex..<completeEnd)
                if throughOffset != nil, decodingLines(completePart) == nil {
                    finished = true
                    return
                }
                pending.removeSubrange(pending.startIndex..<completeEnd)
                consumed += UInt64(completePart.count)
                emit(completePart, batchLines: batchLines, onBatch: onBatch)
            }
            if let failure { return failure }
            if finished { break }
        }
        return .success(newOffset: offset + consumed)
    }

    /// 整段解码失败时与旧实现一致：该段不产出行，但 offset 照常推进，不会下轮重复计费。
    nonisolated private static func emit(
        _ data: Data,
        batchLines: Int,
        onBatch: (ArraySlice<String>) -> Void
    ) {
        // 按 `\n` 字节切段、逐段构造 String，而不是先整段转 String 再 `split(separator:)`。
        // 后者按 Character 切分，要逐位判定 grapheme cluster 边界；本机 sample 实测这一步
        // 的采样数（1361）高于逐行 JSONSerialization 本身（855），是扫描的头号开销。
        // 换行符是 ASCII，因此「整段可解码」与「每行都可解码」等价：任一行解码失败即整段
        // 失败，与旧实现的「整段解码失败则不产出行」逐字节等价。
        guard let lines = decodingLines(data) else { return }
        var index = lines.startIndex
        while index < lines.endIndex {
            let batchEnd = min(index + batchLines, lines.endIndex)
            autoreleasepool {
                onBatch(lines[index..<batchEnd])
            }
            index = batchEnd
        }
    }

    /// 按换行字节切分并逐行 UTF-8 解码；任一行解码失败返回 nil（整段作废）。
    /// 空行按旧实现的 `omittingEmptySubsequences: true` 语义跳过。
    nonisolated private static func decodingLines(_ data: Data) -> [String]? {
        let newline = UInt8(ascii: "\n")
        var lines: [String] = []
        var lineStart = data.startIndex
        while lineStart < data.endIndex {
            guard let breakIndex = data[lineStart...].firstIndex(of: newline) else { break }
            if breakIndex > lineStart {
                guard let line = String(data: data[lineStart..<breakIndex], encoding: .utf8) else {
                    return nil
                }
                lines.append(line)
            }
            lineStart = data.index(after: breakIndex)
        }
        // 末尾无换行的残段：`streamLines` 只会交付到最后一个换行为止，这里是防御性处理，
        // 语义与旧实现的 `split` 保留末段一致。
        if lineStart < data.endIndex {
            guard let line = String(data: data[lineStart...], encoding: .utf8) else { return nil }
            lines.append(line)
        }
        return lines
    }

    /// 读出首行（不含换行），最多 `maxBytes` 字节；`.jsonl.zst` 透明解压。打不开返回 nil。
    nonisolated static func firstLine(url: URL, maxBytes: Int) -> Data? {
        var handle: FileHandle?
        var reader: ZstdStreamReader?
        if JSONLDirectoryEnumerator.isZstd(url) {
            reader = try? ZstdStreamReader(url: url)
        } else {
            handle = try? FileHandle(forReadingFrom: url)
        }
        guard handle != nil || reader != nil else { return nil }
        defer { try? handle?.close() }
        func readChunk(_ count: Int) -> Data? {
            if let reader { return try? reader.read(upToCount: count) }
            return try? handle?.read(upToCount: count)
        }
        var data = Data()
        let newline = UInt8(ascii: "\n")
        while data.count < maxBytes {
            guard let chunk = readChunk(256 << 10), !chunk.isEmpty else { break }
            if let index = chunk.firstIndex(of: newline) {
                data.append(chunk[chunk.startIndex..<index])
                break
            }
            data.append(chunk)
        }
        return data
    }

    nonisolated private static func failureStreamOutcome(for url: URL) -> StreamOutcome {
        FileManager.default.fileExists(atPath: url.path) ? .failed : .missing
    }

    /// 兼容只关心成功与否的调用方；需要区分文件消失与真失败时使用 `readOutcome`。
    nonisolated static func read(url: URL, fromOffset offset: UInt64) -> (lines: [String], newOffset: UInt64)? {
        guard case let .success(lines, newOffset) = readOutcome(url: url, fromOffset: offset) else {
            return nil
        }
        return (lines: lines, newOffset: newOffset)
    }

    nonisolated static func readOutcome(url: URL, fromOffset offset: UInt64) -> ReadOutcome {
        guard let handle = try? FileHandle(forReadingFrom: url) else {
            return failureOutcome(for: url)
        }
        defer { try? handle.close() }

        let end: UInt64
        do {
            end = try handle.seekToEnd()
        } catch {
            return failureOutcome(for: url)
        }
        if offset >= end {
            return .success(lines: [], newOffset: end)
        }
        do {
            try handle.seek(toOffset: offset)
        } catch {
            return failureOutcome(for: url)
        }
        let data: Data
        do {
            data = try handle.readToEnd() ?? Data()
        } catch {
            return failureOutcome(for: url)
        }
        // 必须按整行切：最后一行如果没有换行结尾，则保留为下次偏移之前的残行 → 简单起见，把最后未结束的部分丢回 offset
        guard !data.isEmpty else {
            return .success(lines: [], newOffset: end)
        }
        let newline = UInt8(ascii: "\n")
        var lastNewline: Int = -1
        for i in stride(from: data.count - 1, through: 0, by: -1) {
            if data[i] == newline {
                lastNewline = i
                break
            }
        }
        let completePart: Data
        let newOffset: UInt64
        if lastNewline < 0 {
            // 整段没有换行 → 全是残行，不消费
            return .success(lines: [], newOffset: offset)
        } else {
            completePart = data.subdata(in: 0..<(lastNewline + 1))
            newOffset = offset + UInt64(lastNewline + 1)
        }
        let text = String(data: completePart, encoding: .utf8) ?? ""
        let lines = text.split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
        return .success(lines: lines, newOffset: newOffset)
    }

    nonisolated private static func failureOutcome(for url: URL) -> ReadOutcome {
        FileManager.default.fileExists(atPath: url.path) ? .failed : .missing
    }
}

/// JSONL 行时间戳解析。除了 formatter 实例创建成本高（不能按行新建，这里静态复用
/// 两个固定配置的实例），`date(from:)` 单次调用本身也很贵——内部要走 CFDateFormatter
/// 的通用格式状态机，实测占整轮日志扫描 CPU 的一半以上。JSONL 时间戳形状固定，
/// 先用按字节的手写解析走完绝大多数行，形状不符再回退到 formatter，避免收窄行为。
/// formatter 实例创建后不再修改配置，Foundation 的 formatter 在只读并发使用下是
/// 线程安全的，因此对 Sendable 检查用 nonisolated(unsafe) 显式豁免。
enum JSONLTimestamp {
    nonisolated(unsafe) private static let fractional: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    nonisolated(unsafe) private static let plain: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    /// 小数秒位数 → 除数，避免逐位累乘带来的浮点误差和 `pow` 调用。
    nonisolated private static let fractionScales: [Double] = [
        1, 10, 100, 1_000, 10_000, 100_000,
        1_000_000, 10_000_000, 100_000_000, 1_000_000_000,
    ]

    nonisolated static func parse(_ s: String) -> Date? {
        if let fast = fastParse(s) { return fast }
        if let d = fractional.date(from: s) { return d }
        return plain.date(from: s)
    }

    /// 手写解析 `YYYY-MM-DDTHH:MM:SS[.fff…][Z|±HH[:]MM]`（与 `.withInternetDateTime`
    /// 接受的形状一致）。任何一处不符合就返回 nil，交回 formatter 兜底。
    /// second 上限 59：withInternetDateTime 连标准闰秒位（23:59:60）都拒绝，
    /// 这里同样拒绝，避免 fast 路径比 formatter 更宽容导致结果不一致。
    nonisolated private static func fastParse(_ s: String) -> Date? {
        let parsed: Date?? = s.utf8.withContiguousStorageIfAvailable { buffer in
            parseInternetDateTime(buffer)
        }
        return parsed ?? nil
    }

    nonisolated private static func parseInternetDateTime(
        _ b: UnsafeBufferPointer<UInt8>
    ) -> Date? {
        guard b.count >= 19,
              b[4] == UInt8(ascii: "-"), b[7] == UInt8(ascii: "-"),
              b[10] == UInt8(ascii: "T"),
              b[13] == UInt8(ascii: ":"), b[16] == UInt8(ascii: ":"),
              let year = integer(in: b, from: 0, count: 4),
              let month = integer(in: b, from: 5, count: 2),
              let day = integer(in: b, from: 8, count: 2),
              let hour = integer(in: b, from: 11, count: 2),
              let minute = integer(in: b, from: 14, count: 2),
              let second = integer(in: b, from: 17, count: 2),
              (1...12).contains(month), (1...31).contains(day),
              hour <= 23, minute <= 59, second <= 59
        else { return nil }

        var index = 19
        var fraction: Double = 0
        if index < b.count, b[index] == UInt8(ascii: ".") {
            index += 1
            var digits = 0
            var value = 0
            while index < b.count, let digit = digitValue(b[index]) {
                // 超出 Double 有效精度的尾数直接丢弃，避免溢出。
                if digits < fractionScales.count - 1 {
                    value = value * 10 + digit
                    digits += 1
                }
                index += 1
            }
            guard digits > 0 else { return nil }
            fraction = Double(value) / fractionScales[digits]
        }

        // `.withInternetDateTime` 要求必须带时区，缺时区的输入原本解析失败；
        // 这里同样拒绝，交回 formatter，避免把原来被跳过的行变成有效条目。
        guard index < b.count else { return nil }
        var offsetSeconds = 0
        let marker = b[index]
        if marker == UInt8(ascii: "Z") || marker == UInt8(ascii: "z") {
            index += 1
        } else if marker == UInt8(ascii: "+") || marker == UInt8(ascii: "-") {
            let sign = marker == UInt8(ascii: "+") ? 1 : -1
            index += 1
            guard let offsetHour = integer(in: b, from: index, count: 2) else { return nil }
            index += 2
            if index < b.count, b[index] == UInt8(ascii: ":") { index += 1 }
            var offsetMinute = 0
            if let value = integer(in: b, from: index, count: 2) {
                offsetMinute = value
                index += 2
            }
            offsetSeconds = sign * (offsetHour * 3_600 + offsetMinute * 60)
        } else {
            return nil
        }
        // 还有尾巴说明形状超出这里的假设，不猜，交给 formatter。
        guard index == b.count else { return nil }

        let days = daysFromCivil(year: year, month: month, day: day)
        let seconds = days * 86_400 + hour * 3_600 + minute * 60 + second - offsetSeconds
        return Date(timeIntervalSince1970: Double(seconds) + fraction)
    }

    nonisolated private static func digitValue(_ byte: UInt8) -> Int? {
        guard byte >= UInt8(ascii: "0"), byte <= UInt8(ascii: "9") else { return nil }
        return Int(byte - UInt8(ascii: "0"))
    }

    nonisolated private static func integer(
        in b: UnsafeBufferPointer<UInt8>,
        from start: Int,
        count: Int
    ) -> Int? {
        guard start >= 0, start + count <= b.count else { return nil }
        var value = 0
        for offset in start..<(start + count) {
            guard let digit = digitValue(b[offset]) else { return nil }
            value = value * 10 + digit
        }
        return value
    }

    /// 民用日期 → 距 1970-01-01 的天数（proleptic Gregorian，Howard Hinnant 的
    /// days_from_civil；纯整数运算，不经过 Calendar）。
    nonisolated private static func daysFromCivil(year: Int, month: Int, day: Int) -> Int {
        let y = year - (month <= 2 ? 1 : 0)
        let era = (y >= 0 ? y : y - 399) / 400
        let yearOfEra = y - era * 400                                            // [0, 399]
        let dayOfYear = (153 * (month + (month > 2 ? -3 : 9)) + 2) / 5 + day - 1 // [0, 365]
        let dayOfEra = yearOfEra * 365 + yearOfEra / 4 - yearOfEra / 100 + dayOfYear
        return era * 146_097 + dayOfEra - 719_468
    }
}

/// JSONL 枚举阶段取得的稳定文件元数据，供 Scanner 判断是否需要读取。
/// 避免枚举后再为每个文件重复查询 mtime / size。
struct JSONLFileDescriptor: Sendable {
    var url: URL
    var modificationTime: TimeInterval
    var size: UInt64
    /// 文件创建时间；取不到时为 0。Claude 扫描器按它排序，让续接 / 分叉对话复制过去的消息归给原对话。
    var creationTime: TimeInterval = 0
    /// `.jsonl.zst` 压缩日志；此时 `size` 是压缩后的文件大小，不能与解压后的 offset 比较。
    var isZstd = false

    var path: String { url.path }
}

/// 存在却读不出来的日志文件（或日志根目录）。只在读取已经失败后构造，供诊断日志与界面提示说明原因。
nonisolated struct LogReadFailure: Sendable, Equatable {
    enum Reason: String, Sendable {
        /// 当前用户没有读取权限，例如用 sudo 运行过留下的 root 文件。
        case permissionDenied
        /// `.jsonl.zst` 有读取权限但解压失败：压缩日志损坏或不完整。
        case decompressFailed
        /// 根目录或其中的路径无法读取。
        case directoryUnavailable
        /// 其他读取错误，例如磁盘 I/O 错误。
        case readFailed
    }

    var path: String
    var reason: Reason

    /// 按失败后的文件状态归因：只在失败路径上多做一次访问检查。
    static func classify(_ url: URL) -> LogReadFailure {
        let reason: Reason
        if !FileManager.default.isReadableFile(atPath: url.path) {
            reason = .permissionDenied
        } else if JSONLDirectoryEnumerator.isZstd(url) {
            reason = .decompressFailed
        } else {
            reason = .readFailed
        }
        return LogReadFailure(path: url.path, reason: reason)
    }
}

/// 递归列出某目录下后缀为 .jsonl 的文件，并同时取得增量扫描所需元数据。
enum JSONLDirectoryEnumerator {
    struct Result: Sendable {
        var files: [JSONLFileDescriptor]
        /// 根目录存在但不是目录，或枚举器无法打开。
        var accessFailed: Bool
        var enumerationIncomplete = false
    }

    nonisolated static let zstdSuffix = ".jsonl.zst"

    nonisolated static func isZstd(_ url: URL) -> Bool {
        url.lastPathComponent.lowercased().hasSuffix(zstdSuffix)
    }

    /// 日志是否仍在。Codex 把冷会话压成同名 `.jsonl.zst`、resume 时再解压回 `.jsonl`，
    /// 两种形态任一存在都算同一份日志还在。
    nonisolated static func sourceExists(atPath path: String) -> Bool {
        let fm = FileManager.default
        if fm.fileExists(atPath: path) { return true }
        if path.lowercased().hasSuffix(zstdSuffix) {
            return fm.fileExists(atPath: String(path.dropLast(".zst".count)))
        }
        return path.lowercased().hasSuffix(".jsonl") && fm.fileExists(atPath: path + ".zst")
    }

    /// - Parameter minimumMtime: 非 nil 时只返回修改时间不早于该时刻的文件。
    ///   供周期用量的受限重建过滤"最近窗口之外"的旧日志使用；nil 时行为与原来一致。
    nonisolated static func files(at root: URL, minimumMtime: Date? = nil) -> [JSONLFileDescriptor] {
        enumerate(at: root, minimumMtime: minimumMtime).files
    }

    /// - Parameter includeZstd: 同时收 `.jsonl.zst`（Codex 压缩的冷会话）。同目录下
    ///   明文与压缩并存时只取明文，与 Codex 自身的读取优先级一致。
    nonisolated static func enumerate(
        at root: URL,
        minimumMtime: Date? = nil,
        includeZstd: Bool = false
    ) -> Result {
        let fm = FileManager.default
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: root.path, isDirectory: &isDir) else {
            return Result(files: [], accessFailed: false)
        }
        guard isDir.boolValue else {
            return Result(files: [], accessFailed: true)
        }
        var enumerationIncomplete = false
        guard let it = fm.enumerator(
            at: root,
            includingPropertiesForKeys: [
                .isRegularFileKey,
                .contentModificationDateKey,
                .creationDateKey,
                .fileSizeKey,
            ],
            options: [.skipsHiddenFiles],
            errorHandler: { _, _ in
                enumerationIncomplete = true
                return true
            }
        ) else {
            return Result(files: [], accessFailed: true)
        }
        var result: [JSONLFileDescriptor] = []
        var plainPaths: Set<String> = []
        for case let url as URL in it {
            let compressed = includeZstd && isZstd(url)
            guard compressed || url.pathExtension.lowercased() == "jsonl" else { continue }
            if !compressed { plainPaths.insert(url.path) }
            let values = try? url.resourceValues(forKeys: [
                .contentModificationDateKey,
                .creationDateKey,
                .fileSizeKey,
            ])
            let modificationDate = values?.contentModificationDate
            if values == nil { enumerationIncomplete = true }
            if let minimumMtime {
                guard let modificationDate, modificationDate >= minimumMtime else { continue }
            }
            result.append(JSONLFileDescriptor(
                url: url,
                modificationTime: modificationDate?.timeIntervalSince1970 ?? 0,
                size: UInt64(max(0, values?.fileSize ?? 0)),
                creationTime: values?.creationDate?.timeIntervalSince1970 ?? 0,
                isZstd: compressed
            ))
        }
        if includeZstd {
            // 明文按 minimumMtime 过滤前就记入 plainPaths：被过滤的明文同样遮住它的压缩副本。
            result.removeAll { $0.isZstd && plainPaths.contains(String($0.path.dropLast(".zst".count))) }
        }
        return Result(files: result, accessFailed: false, enumerationIncomplete: enumerationIncomplete)
    }
}
