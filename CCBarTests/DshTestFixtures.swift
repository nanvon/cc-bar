import Foundation
import libzstd

/// DSH 测试共用 fixture：用工程链接的 libzstd 现场编码 zstd 帧，并生成**脱敏合成**的会话日志。
///
/// 记录形状取自 DSH 随包源码，不依赖本机任何真实会话日志、也不调用 `zstd` 命令：
///   - 事件信封 `{type, time(ms), data, ...}`（`dsh-session`）；
///   - `session` 头 `{version, id, cwd, parentSession, delegationDepth, agentPreset, isSeeded, createdAt}`；
///   - `session/title` `data.{title, messageSeqs, source}`（`dsh-session-title`）；
///   - `assistant/message` `data.{message.source.{provider,model}, usage}`，
///     usage 必填 `inputTokens` / `outputTokens`，可选 `totalTokens` / `cacheReadTokens` /
///     `cacheWriteTokens` / `reasoningTokens`（`dsh-session-format-v0-to-v1` 的 `tokenUsageValue`）。
enum DshTestFixtures {
    enum FixtureError: Error {
        case contextCreation
        case parameterRejected
        case compressionFailed
    }

    // MARK: - zstd 编码

    /// 一次性压缩：产出 single segment 帧（帧头含 content size）。
    static func frame(_ payload: Data, checksum: Bool = true) throws -> Data {
        guard let context = ZSTD_createCCtx() else { throw FixtureError.contextCreation }
        defer { ZSTD_freeCCtx(context) }
        guard ZSTD_isError(ZSTD_CCtx_setParameter(context, ZSTD_c_checksumFlag, checksum ? 1 : 0)) == 0 else {
            throw FixtureError.parameterRejected
        }

        let bound = Int(ZSTD_compressBound(payload.count))
        var output = Data(count: bound)
        let written = output.withUnsafeMutableBytes { destination -> Int in
            payload.withUnsafeBytes { source -> Int in
                ZSTD_compress2(context, destination.baseAddress, bound, source.baseAddress, payload.count)
            }
        }
        guard ZSTD_isError(written) == 0 else { throw FixtureError.compressionFailed }
        output.removeSubrange(written..<bound)
        return output
    }

    /// 流式压缩且不写 content size：帧头是 window descriptor 形态（single segment 位为 0）。
    static func streamingFrame(_ payload: Data, checksum: Bool = true) throws -> Data {
        guard let context = ZSTD_createCCtx() else { throw FixtureError.contextCreation }
        defer { ZSTD_freeCCtx(context) }
        guard ZSTD_isError(ZSTD_CCtx_setParameter(context, ZSTD_c_checksumFlag, checksum ? 1 : 0)) == 0,
              ZSTD_isError(ZSTD_CCtx_setParameter(context, ZSTD_c_contentSizeFlag, 0)) == 0
        else {
            throw FixtureError.parameterRejected
        }

        let bound = Int(ZSTD_compressBound(payload.count)) + 1024
        var output = Data(count: bound)
        let written = output.withUnsafeMutableBytes { destination -> Int in
            payload.withUnsafeBytes { source -> Int in
                var input = ZSTD_inBuffer(src: source.baseAddress, size: payload.count, pos: 0)
                var chunk = ZSTD_outBuffer(dst: destination.baseAddress, size: bound, pos: 0)
                var remaining = ZSTD_compressStream2(context, &chunk, &input, ZSTD_e_end)
                while remaining != 0, ZSTD_isError(remaining) == 0 {
                    remaining = ZSTD_compressStream2(context, &chunk, &input, ZSTD_e_end)
                }
                return ZSTD_isError(remaining) == 0 ? chunk.pos : -1
            }
        }
        guard written >= 0 else { throw FixtureError.compressionFailed }
        output.removeSubrange(written..<bound)
        return output
    }

    /// 一帧一批：DSH 每批追加一个可独立解码的帧。
    static func log(_ batches: [[String: Any]], checksum: Bool = true) throws -> Data {
        var output = Data()
        for batch in batches {
            output.append(try frame(line(batch), checksum: checksum))
        }
        return output
    }

    /// 一帧多行：帧内可以放多条记录。
    static func log(lines: [[String: Any]], linesPerFrame: Int = 1, checksum: Bool = true) throws -> Data {
        var output = Data()
        var index = 0
        while index < lines.count {
            let slice = lines[index..<min(index + linesPerFrame, lines.count)]
            var payload = Data()
            for record in slice { payload.append(line(record)) }
            output.append(try frame(payload, checksum: checksum))
            index += linesPerFrame
        }
        return output
    }

    static func line(_ record: [String: Any]) -> Data {
        var data = (try? JSONSerialization.data(withJSONObject: record)) ?? Data()
        data.append(UInt8(ascii: "\n"))
        return data
    }

    // MARK: - 记录构造

    static let baseTime: Double = 1_780_000_000_000  // Unix ms

    static func session(
        id: String,
        cwd: String? = "/Users/tester/Code/demo",
        parentSession: String? = nil,
        delegationDepth: Int = 0,
        time: Double = baseTime
    ) -> [String: Any] {
        var record: [String: Any] = [
            "type": "session",
            "version": 3,
            "id": id,
            "delegationDepth": delegationDepth,
            "agentPreset": "default",
            "isSeeded": false,
            "createdAt": time,
            "time": time
        ]
        if let cwd { record["cwd"] = cwd }
        if let parentSession { record["parentSession"] = parentSession }
        return record
    }

    static func title(_ text: String, time: Double = baseTime + 1_000) -> [String: Any] {
        [
            "type": "session/title",
            "time": time,
            "data": [
                "title": text,
                "messageSeqs": [1],
                "source": ["kind": "fallback"]
            ]
        ]
    }

    static func assistant(
        time: Double,
        provider: String? = "deepseek",
        model: String? = "deepseek-v4.1-flash",
        input: Int = 100,
        output: Int = 50,
        cacheRead: Int = 10,
        cacheWrite: Int = 0,
        totalTokens: Int? = nil,
        usage: [String: Any]? = nil,
        streamOnly: Bool = false,
        turn: Int? = nil,
        step: Int = 1
    ) -> [String: Any] {
        var source: [String: Any] = ["kind": "model"]
        if let provider { source["provider"] = provider }
        if let model { source["model"] = model }

        var body: [String: Any] = [
            "turn": turn ?? max(1, Int((time - baseTime) / 1_000) + 1),
            "step": step,
            "message": [
                "role": "assistant",
                "content": [["type": "text", "text": "hi"]],
                "source": source
            ]
        ]
        let payload: [String: Any] = usage ?? [
            "inputTokens": input,
            "outputTokens": output,
            "cacheReadTokens": cacheRead,
            "cacheWriteTokens": cacheWrite,
            "reasoningTokens": 7
        ]
        if streamOnly {
            body["stream"] = [
                ["type": "chunk", "time": time, "chunk": ["type": "usage", "usage": payload]]
            ]
        } else {
            var withTotal = payload
            if let totalTokens { withTotal["totalTokens"] = totalTokens }
            body["usage"] = withTotal
        }
        return ["type": "assistant/message", "time": time, "data": body]
    }

    /// 同时带 `data.usage` 与 `data.stream`（两处是同一份用量，不可相加）。
    static func assistantWithBoth(
        time: Double,
        provider: String? = "deepseek",
        model: String? = "deepseek-v4.1-flash",
        usage: [String: Any],
        streamUsage: [String: Any]
    ) -> [String: Any] {
        var record = assistant(time: time, provider: provider, model: model, usage: usage)
        var body = record["data"] as? [String: Any] ?? [:]
        body["stream"] = [
            ["type": "chunk", "time": time, "chunk": ["type": "usage", "usage": streamUsage]]
        ]
        record["data"] = body
        return record
    }
}

// MARK: - 临时日志目录

/// 在临时目录里搭 `sessions/<项目段>/<会话段>/<日志>` 结构，避免碰真实 `~/.dsh/sessions`。
final class DshTempLogRoot {
    let root: URL

    init(name: String) throws {
        let raw = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(name)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: raw, withIntermediateDirectories: true)
        root = raw.path.withCString { path in
            guard let resolved = realpath(path, nil) else { return raw }
            defer { free(resolved) }
            return URL(fileURLWithPath: String(cString: resolved), isDirectory: true)
        }
    }

    deinit {
        try? FileManager.default.removeItem(at: root)
    }

    /// 建一个会话目录并写入日志文件（同名覆盖）。
    @discardableResult
    func write(project: String, session: String, file: String, bytes: Data, modified: Date? = nil) throws -> URL {
        let directory = root
            .appendingPathComponent(project, isDirectory: true)
            .appendingPathComponent(session, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent(file)
        try bytes.write(to: url)
        if let modified {
            try FileManager.default.setAttributes([.modificationDate: modified], ofItemAtPath: url.path)
        }
        return url
    }
}
