import Foundation
import SQLite3
import CryptoKit

/// 只读 Antigravity（2.0 App / IDE / agy CLI）的本机对话库 `<数据根>/conversations/<对话 ID>.db`。
///
/// 每个对话一个 SQLite 库，每次模型请求在 `gen_metadata` 里有一行 protobuf，用量是其中的
/// `ModelUsageStats`：1 模型编号、2 非缓存输入、3 输出（思考 + 正文）、4 缓存写入、5 缓存读取、
/// 7 消息 ID、9 思考输出、10 正文输出、11 响应 ID、12 提供方消息 ID。被重试的请求另记在
/// `steps.metadata` 字段 28 与 `gen_metadata` 的重试字段里，按响应 ID 去重后一并计入。
/// 字段含义没有公开文档，来自本机数据核对，并与 ccusage、codeburn 的解析一致。
///
/// 同一对话可能出现在多个数据根（2.0 迁移留下的 `antigravity-ide` / `antigravity-backup` 复制），
/// 按对话 ID 合并、按响应 ID 去重。变动对话整体重读，调用方替换该对话的贡献；
/// 源库删除的对话保留旧签名和用量。只读元数据表，不读对话正文（`steps.step_payload`）。
nonisolated enum AntigravityScanner {
    nonisolated struct FileSignature: Sendable, Codable, Equatable {
        var size: Int64
        var modified: Double
        var walSize: Int64
        var walModified: Double
    }

    nonisolated struct State: Sendable, Codable, Equatable {
        static let currentVersion = 1
        var version = Self.currentVersion
        /// 对话 ID → 库文件路径 → 读取时的签名。
        var conversations: [String: [String: FileSignature]] = [:]
        /// 标题独立变化时只刷新对应会话；旧状态缺少该字段时兼容。
        var titleHashes: [String: String]?
    }

    nonisolated struct Result: Sendable {
        /// 本轮刷新对话的完整贡献，不能作为新增条目累加。
        var entries: [UsageEntry] = []
        var conversationSeeds: [ConversationSeed] = []
        var refreshedConversationIDs: Set<String> = []
        var newState: State?
        var databasesRead = 0
        /// 读不出的库文件数；对应对话保留旧贡献，下一轮重试。
        var failedDatabaseCount = 0
        var isComplete = false
    }

    /// 2.0 App、IDE、CLI 与迁移 / 备份目录。目录不存在时跳过。
    static func defaultRoots() -> [URL] {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return [
            ".gemini/antigravity",
            ".gemini/antigravity-cli",
            ".gemini/antigravity-ide",
            ".gemini/antigravity-backup",
            ".gemini/antigravity-acp",
            ".config/antigravity",
        ].map { home.appendingPathComponent($0, isDirectory: true) }
    }

    static func conversationDirectories(roots: [URL]) -> [URL] {
        roots.map { $0.appendingPathComponent("conversations", isDirectory: true) }
    }

    static func scan(
        previous: State?,
        roots: [URL],
        onProgress: ScanProgressCallback? = nil
    ) -> Result {
        let baseline = previous?.version == State.currentVersion ? previous : nil
        var state = baseline ?? State()
        var result = Result()
        let files = conversationFiles(roots: roots)

        var titles = loadTitles(roots: roots)
        for id in files.keys {
            if let title = annotationTitle(id: id, roots: roots) { titles[id] = title }
        }
        let titleHashes = Dictionary(uniqueKeysWithValues: files.keys.map { id in
            (id, SHA256.hash(data: Data((titles[id] ?? "").utf8)).map { String(format: "%02x", $0) }.joined())
        })
        var changed: [(id: String, signatures: [String: FileSignature], urls: [URL])] = []
        for id in files.keys.sorted() {
            guard let urls = files[id] else { continue }
            var signatures: [String: FileSignature] = [:]
            for url in urls {
                if let signature = signature(of: url) { signatures[url.path] = signature }
            }
            let old = baseline?.conversations[id] ?? [:]
            // 删除了副本但其余副本未变化时保留旧贡献；标题单独改变时仍刷新。
            guard signatures.contains(where: { old[$0.key] != $0.value })
                    || baseline?.titleHashes?[id] != titleHashes[id] else { continue }
            changed.append((id, signatures, urls))
        }
        guard !changed.isEmpty else {
            result.newState = state
            result.isComplete = true
            return result
        }

        var projectResolver = ConversationProjectResolver()
        for (index, item) in changed.enumerated() {
            onProgress?(ScanProgress(app: .antigravity, filesCompleted: index,
                                     filesTotal: changed.count, linesParsed: result.databasesRead))
            let read = readConversation(id: item.id, urls: item.urls)
            result.databasesRead += read.readPaths.count
            result.failedDatabaseCount += read.failedCount
            // 全部副本都读不出：保留旧贡献和旧签名，下一轮重试。
            guard !read.readPaths.isEmpty else { continue }

            let entries = read.records.map { makeEntry(conversationID: item.id, record: $0) }
            result.entries.append(contentsOf: entries)
            result.refreshedConversationIDs.insert(item.id)
            if !entries.isEmpty {
                result.conversationSeeds.append(ConversationSeed(
                    key: "antigravity:\(item.id)", id: item.id, app: .antigravity,
                    title: titles[item.id],
                    project: projectResolver.resolve(rawPath: read.workspacePath ?? "", source: .cwd),
                    gitBranch: read.gitBranch,
                    sourcePath: read.readPaths[0],
                    includesSubtasks: false,
                    cacheCreationAvailable: true
                ))
            }
            // 只记读成功的副本：读失败的副本下一轮仍算变化，会重试。
            state.conversations[item.id] = item.signatures.filter { read.readPaths.contains($0.key) }
            if state.titleHashes == nil { state.titleHashes = [:] }
            state.titleHashes?[item.id] = titleHashes[item.id]
        }
        result.newState = state
        result.isComplete = true
        return result
    }

    // MARK: - 文件发现

    /// 对话 ID → 各数据根里的库文件。同一真实路径（符号链接）只取一次。
    private static func conversationFiles(roots: [URL]) -> [String: [URL]] {
        let fileManager = FileManager.default
        var result: [String: [URL]] = [:]
        var seen = Set<String>()
        for directory in conversationDirectories(roots: roots) {
            var isDirectory: ObjCBool = false
            guard fileManager.fileExists(atPath: directory.path, isDirectory: &isDirectory),
                  isDirectory.boolValue,
                  let names = try? fileManager.contentsOfDirectory(atPath: directory.path)
            else { continue }
            for name in names.sorted() where name.hasSuffix(".db") {
                let url = directory.appendingPathComponent(name, isDirectory: false)
                guard seen.insert(url.resolvingSymlinksInPath().path).inserted else { continue }
                let id = String(name.dropLast(3))
                guard !id.isEmpty else { continue }
                result[id, default: []].append(url)
            }
        }
        return result
    }

    private static func signature(of url: URL) -> FileSignature? {
        let fileManager = FileManager.default
        guard let attributes = try? fileManager.attributesOfItem(atPath: url.path) else { return nil }
        let wal = try? fileManager.attributesOfItem(atPath: url.path + "-wal")
        return FileSignature(
            size: (attributes[.size] as? NSNumber)?.int64Value ?? 0,
            modified: (attributes[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0,
            walSize: (wal?[.size] as? NSNumber)?.int64Value ?? 0,
            walModified: (wal?[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
        )
    }

    /// 有标题库时兼容读取；GUI 的权威自定义标题优先取 annotations/<id>.pbtxt。
    private static func loadTitles(roots: [URL]) -> [String: String] {
        var titles: [String: String] = [:]
        for root in roots {
            // GUI 自动标题：SummariesState 的 map<string, CascadeTrajectorySummary>。
            let summary = root.appendingPathComponent("agyhub_summaries_proto.pb")
            if let size = (try? FileManager.default.attributesOfItem(atPath: summary.path))?[.size] as? NSNumber,
               size.intValue <= 32 * 1_048_576, let data = try? Data(contentsOf: summary),
               let state = Proto.fields(Array(data)) {
                for bytes in state.allBytes(1) {
                    guard let entry = Proto.fields(bytes), let id = entry.text(1), titles[id] == nil,
                          let title = ConversationTitleIndex.clean(entry.message(2)?.text(1)) else { continue }
                    titles[id] = title
                }
            }
            let url = root.appendingPathComponent("conversation_summaries.db", isDirectory: false)
            guard FileManager.default.fileExists(atPath: url.path) else { continue }
            try? withDatabase(url) { db in
                guard try columns(db, table: "conversation_summaries")
                    .isSuperset(of: ["conversation_id", "title"]) else { return }
                try rows(db, sql: "SELECT conversation_id, title FROM conversation_summaries") { stmt in
                    guard let id = columnText(stmt, 0), titles[id] == nil,
                          let title = ConversationTitleIndex.clean(columnText(stmt, 1)) else { return }
                    titles[id] = title
                }
            }
        }
        return titles
    }

    private static func annotationTitle(id: String, roots: [URL]) -> String? {
        for root in roots {
            let url = root.appendingPathComponent("annotations/\(id).pbtxt")
            guard let size = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? NSNumber,
                  size.intValue <= 1_048_576, let data = try? Data(contentsOf: url),
                  let title = parseAnnotationTitle(data) else { continue }
            return title
        }
        return nil
    }

    /// Protobuf text string 与 JSON 的常规转义兼容，另外允许 UTF-8 字节的八进制转义。
    static func parseAnnotationTitle(_ data: Data) -> String? {
        guard let text = String(data: data, encoding: .utf8),
              let expression = try? NSRegularExpression(pattern: #"(?m)^\s*title\s*:\s*\"((?:\\.|[^\"\\])*)\""#),
              let match = expression.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              let range = Range(match.range(at: 1), in: text) else { return nil }
        let quoted = "\"" + text[range] + "\""
        if let value = try? JSONDecoder().decode(String.self, from: Data(quoted.utf8)) {
            return ConversationTitleIndex.clean(value)
        }
        let bytes = Array(text[range].utf8)
        var result: [UInt8] = []
        var index = 0
        let escapes: [UInt8: UInt8] = [97: 7, 98: 8, 102: 12, 110: 10, 114: 13, 116: 9, 118: 11,
                                      92: 92, 34: 34, 39: 39, 63: 63]
        while index < bytes.count {
            let value = bytes[index]
            index += 1
            guard value == 92 else { result.append(value); continue }
            guard index < bytes.count else { return nil }
            if (48...55).contains(bytes[index]) {
                var octal = 0
                var count = 0
                while index < bytes.count, count < 3, (48...55).contains(bytes[index]) {
                    octal = octal * 8 + Int(bytes[index] - 48)
                    index += 1
                    count += 1
                }
                guard octal <= 255 else { return nil }
                result.append(UInt8(octal))
            } else if let escaped = escapes[bytes[index]] {
                result.append(escaped)
                index += 1
            } else { return nil }
        }
        return String(bytes: result, encoding: .utf8).flatMap(ConversationTitleIndex.clean)
    }

    // MARK: - 读取

    nonisolated struct UsageRecord: Sendable, Equatable {
        /// 去重键：响应 ID 优先，其次提供方消息 ID、消息 ID；生成行都没有时用行号。
        var identity: String
        var model: String?
        var timestamp: Date?
        var input: Int
        var output: Int
        var cacheRead: Int
        var cacheCreation: Int
        var timing: RequestTiming? = nil
    }

    private nonisolated struct ConversationRead {
        var records: [UsageRecord] = []
        var workspacePath: String?
        var gitBranch: String?
        var readPaths: [String] = []
        var failedCount = 0
    }

    private nonisolated struct DatabaseRead {
        var records: [UsageRecord] = []
        var workspacePath: String?
        var gitBranch: String?
        var createdAt: Date?
    }

    private static func readConversation(id: String, urls: [URL]) -> ConversationRead {
        var read = ConversationRead()
        var seen = Set<String>()
        for url in urls {
            let database: DatabaseRead
            do {
                database = try readDatabase(url)
            } catch {
                read.failedCount += 1
                continue
            }
            read.readPaths.append(url.path)
            read.workspacePath = read.workspacePath ?? database.workspacePath
            read.gitBranch = read.gitBranch ?? database.gitBranch
            let modified = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date
            for var record in database.records where seen.insert(record.identity).inserted {
                record.timestamp = record.timestamp ?? database.createdAt ?? modified
                read.records.append(record)
            }
        }
        return read
    }

    private nonisolated struct ReadFailure: Error, CustomStringConvertible {
        var detail: String
        var code: Int32?
        var description: String { detail }
    }

    private nonisolated struct StepInfo {
        var timestamp: Date?
        var model: String?
        var usages: [(identity: String?, usage: UsageCounts, modelID: UInt64?)]
    }

    private nonisolated struct UsageCounts {
        var input: Int
        var output: Int
        var cacheRead: Int
        var cacheCreation: Int
    }

    private static func readDatabase(_ url: URL) throws -> DatabaseRead {
        var read = DatabaseRead()
        try withDatabase(url) { db in
            let tables = try tableNames(db)

            if tables.contains("trajectory_metadata_blob") {
                try rows(db, sql: "SELECT data FROM trajectory_metadata_blob") { stmt in
                    guard read.createdAt == nil, let blob = columnBlob(stmt, 0),
                          let fields = Proto.fields(blob) else { return }
                    if let workspace = fields.message(1) {
                        read.workspacePath = workspace.text(1).map(filePath)
                        read.gitBranch = workspace.text(4)
                    }
                    read.createdAt = fields.message(2).flatMap(timestamp)
                }
            }

            var steps: [Int64: StepInfo] = [:]
            if tables.contains("steps"), try columns(db, table: "steps").isSuperset(of: ["idx", "metadata"]) {
                try rows(db, sql: "SELECT idx, metadata FROM steps ORDER BY idx") { stmt in
                    // step 元数据只提供时间和重试用量；单条解析不了不影响生成行。
                    guard let blob = columnBlob(stmt, 1), let fields = Proto.fields(blob) else { return }
                    steps[sqlite3_column_int64(stmt, 0)] = stepInfo(fields)
                }
            }

            var currentModel: String?
            if tables.contains("gen_metadata") {
                try rows(db, sql: "SELECT idx, data FROM gen_metadata ORDER BY idx") { stmt in
                    let idx = sqlite3_column_int64(stmt, 0)
                    guard let blob = columnBlob(stmt, 1) else { return }
                    guard let root = Proto.fields(blob) else {
                        throw ReadFailure(detail: "invalid generation metadata")
                    }
                    guard let chat = root.message(1) else { return }
                    let attributes = attributes(chat)
                    let usageFields = chat.message(4)
                    if let resolved = resolveModel(
                        name: chat.text(19),
                        modelID: chat.varint(3) ?? usageFields?.varint(1),
                        placeholder: attributes["model_enum"],
                        displayName: chat.text(21)
                    ) {
                        currentModel = resolved
                    }
                    var time = chat.message(9)?.message(4).flatMap(timestamp)
                    if time == nil, let step = attributes["last_step_index"].flatMap({ Int64($0) }) {
                        time = steps[step]?.timestamp
                    }
                    if let usageFields, let usage = usageCounts(usageFields) {
                        read.records.append(record(
                            identity: identity(usageFields) ?? "row:\(idx)",
                            model: currentModel, timestamp: time, usage: usage,
                            timing: generationTiming(chat)
                        ))
                    }
                    // 重试记录没有 ID 时无法和主用量区分，不计入。
                    for retry in chat.allBytes(17) {
                        guard let retryFields = Proto.fields(retry), let usageFields = retryFields.message(2),
                              let id = identity(usageFields), let usage = usageCounts(usageFields) else { continue }
                        read.records.append(record(identity: id, model: currentModel, timestamp: time, usage: usage))
                    }
                }
            }

            // step 里的用量大多与生成行重复，只补响应 ID 没出现过的（主要是重试）；没有 ID 的不计。
            for idx in steps.keys.sorted() {
                guard let step = steps[idx] else { continue }
                for item in step.usages {
                    guard let id = item.identity else { continue }
                    let stepModel = step.model ?? item.modelID.flatMap { model(forID: $0) } ?? currentModel
                    read.records.append(record(identity: id, model: stepModel, timestamp: step.timestamp, usage: item.usage))
                }
            }
        }
        return read
    }

    private static func record(
        identity: String, model: String?, timestamp: Date?, usage: UsageCounts, timing: RequestTiming? = nil
    ) -> UsageRecord {
        UsageRecord(identity: identity, model: model, timestamp: timestamp, input: usage.input,
                    output: usage.output, cacheRead: usage.cacheRead, cacheCreation: usage.cacheCreation,
                    timing: timing)
    }

    /// ChatModelMetadata 字段 12 为 streaming_duration（google.protobuf.Duration）。
    /// 只用于本条主请求；重试的独立用量没有自己的耗时时不套用。
    private static func generationTiming(_ chat: [Proto.Field]) -> RequestTiming? {
        guard let duration = chat.message(12) else { return nil }
        let seconds = duration.varint(1) ?? 0
        let nanos = duration.varint(2) ?? 0
        guard nanos < 1_000_000_000 else { return nil }
        return RequestTiming(generationMs: Double(seconds) * 1000 + Double(nanos) / 1_000_000)
    }

    private static func stepInfo(_ fields: [Proto.Field]) -> StepInfo {
        var info = StepInfo(
            timestamp: (fields.message(1) ?? fields.message(8)).flatMap(timestamp),
            model: nil,
            usages: []
        )
        if let modelInfo = fields.message(24) {
            info.model = resolveModel(
                name: modelInfo.text(12) ?? modelInfo.text(8),
                modelID: modelInfo.varint(1),
                placeholder: nil,
                displayName: nil
            )
        }
        var usageMessages: [[Proto.Field]] = fields.message(9).map { [$0] } ?? []
        for retry in fields.allBytes(28) {
            if let usage = Proto.fields(retry)?.message(2) { usageMessages.append(usage) }
        }
        for usageFields in usageMessages {
            guard let usage = usageCounts(usageFields) else { continue }
            info.usages.append((identity(usageFields), usage, usageFields.varint(1)))
        }
        return info
    }

    private static func usageCounts(_ fields: [Proto.Field]) -> UsageCounts? {
        func int(_ number: Int) -> Int { Int(clamping: fields.varint(number) ?? 0) }
        let input = int(2)
        let totalOutput = int(3)
        let output = totalOutput > 0 ? totalOutput : int(9) + int(10)
        let counts = UsageCounts(input: input, output: output, cacheRead: int(5), cacheCreation: int(4))
        guard counts.input + counts.output + counts.cacheRead + counts.cacheCreation > 0 else { return nil }
        return counts
    }

    /// 只用一个去重键：同一消息的重试可能共用消息 ID，但响应 ID 不同，要分别计入。
    private static func identity(_ fields: [Proto.Field]) -> String? {
        if let id = fields.text(11) { return "response:\(id)" }
        if let id = fields.text(12) { return "provider:\(id)" }
        if let id = fields.text(7) { return "message:\(id)" }
        return nil
    }

    /// 生成元数据里的键值对（`model_enum`、`last_step_index` 等）。
    private static func attributes(_ chat: [Proto.Field]) -> [String: String] {
        var result: [String: String] = [:]
        for pair in chat.allBytes(20) {
            guard let fields = Proto.fields(pair), let key = fields.text(1), let value = fields.text(2) else { continue }
            result[key] = value
        }
        return result
    }

    /// `google.protobuf.Timestamp`：1 秒、2 纳秒。只接受合理范围，避免把别的整数当成时间。
    private static func timestamp(_ fields: [Proto.Field]) -> Date? {
        guard let seconds = fields.varint(1), seconds > 1_500_000_000, seconds < 4_102_444_800 else { return nil }
        let nanos = Double(fields.varint(2) ?? 0) / 1_000_000_000
        return Date(timeIntervalSince1970: Double(seconds) + nanos)
    }

    private static func filePath(_ uri: String) -> String {
        guard uri.hasPrefix("file://"), let url = URL(string: uri) else { return uri }
        return url.path
    }

    private static func makeEntry(conversationID: String, record: UsageRecord) -> UsageEntry {
        let timestamp = record.timestamp ?? Date(timeIntervalSince1970: 0)
        let model = record.model ?? "unknown"
        let total = record.input + record.output + record.cacheRead + record.cacheCreation
        let breakdown = Pricing.resolveCostBreakdown(
            app: .antigravity,
            model: model,
            speed: .standard,
            input: record.input,
            output: record.output,
            cacheRead: record.cacheRead,
            cacheCreation: record.cacheCreation,
            totalTokens: total,
            reportedCost: nil,
            reportedBreakdown: nil,
            at: timestamp,
            inputTotal: record.input + record.cacheRead + record.cacheCreation
        )
        return UsageEntry(
            app: .antigravity,
            conversationKey: "antigravity:\(conversationID)",
            model: model,
            speed: .standard,
            day: UsageDay.startOfDay(for: timestamp),
            timestamp: timestamp,
            inputTokens: record.input,
            outputTokens: record.output,
            cacheReadTokens: record.cacheRead,
            cacheCreationTokens: record.cacheCreation,
            requestCount: 1,
            costUSD: breakdown?.total,
            costBreakdown: breakdown,
            timing: record.timing
        )
    }

    // MARK: - 模型名

    /// 解析顺序：日志里的具体模型名 → 模型编号 → 占位编号 → 展示名 → 通用名兜底。
    /// 2.0 App 只写占位编号和 `gemini-pro-default` 这类通用名，要靠编号映射；
    /// 编号映射可能随 Antigravity 版本变化，所以具体模型名优先。
    static func resolveModel(
        name: String?,
        modelID: UInt64?,
        placeholder: String?,
        displayName: String?
    ) -> String? {
        if let name, let model = concreteModel(name) { return model }
        if let modelID, modelID != 0, let model = model(forID: modelID) { return model }
        if let placeholder, let model = placeholderModel(placeholder) { return model }
        if let displayName, let model = concreteModel(displayName) { return model }
        if let name, name.lowercased().hasPrefix("gemini-pro") { return "gemini-3.1-pro" }
        return nil
    }

    /// 去掉 Antigravity 的档位、试用、实验等后缀，得到可查价的模型名。通用名返回 nil。
    static func concreteModel(_ raw: String) -> String? {
        var model = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !model.isEmpty else { return nil }
        if model.hasPrefix("model_placeholder_m") { return placeholderModel(model) }
        if let alias = aliases[model] { return alias }
        // 展示名形如 `Gemini 3.8 Flash (High)`。
        if model.contains(" ") {
            if let paren = model.firstIndex(of: "(") { model = String(model[..<paren]) }
            model = model.trimmingCharacters(in: .whitespaces)
                .split(separator: " ").joined(separator: "-")
        }
        if genericNames.contains(model) || model.hasSuffix("-default") || model.contains("-agent") {
            return nil
        }
        let suffixes = [#"-(thinking|trial|extra-low|high|medium|low|n)$"#, #"-exp(-[a-z0-9]+)?$"#]
        var stripped = true
        while stripped {
            stripped = false
            for pattern in suffixes {
                if let range = model.range(of: pattern, options: .regularExpression) {
                    model.removeSubrange(range)
                    stripped = true
                }
            }
        }
        return aliases[model] ?? model
    }

    static func model(forID id: UInt64) -> String? {
        id >= 1000 ? placeholderModels[Int(clamping: id - 1000)] : legacyModelIDs[Int(clamping: id)]
    }

    static func placeholderModel(_ raw: String) -> String? {
        let lower = raw.lowercased()
        guard lower.hasPrefix("model_placeholder_m"),
              let number = Int(lower.dropFirst("model_placeholder_m".count)) else { return nil }
        return placeholderModels[number]
    }

    private static let genericNames: Set<String> = ["gemini-internal-model"]

    private static let aliases: [String: String] = [
        "gemini-3-flash": "gemini-3-flash-preview",
        "gemini-3.1-pro-preview": "gemini-3.1-pro",
        "model_openai_gpt_oss_120b_medium": "gpt-oss-120b",
    ]

    /// `MODEL_PLACEHOLDER_M<n>`，生成元数据里的模型编号为 1000 + n。
    /// 依据本机数据与 ccusage / codeburn 的映射（codeburn 取自 App 2.19 的模型目录）；
    /// M84 两家结论不同，不收录。
    private static let placeholderModels: [Int: String] = [
        16: "gemini-3.1-pro", 36: "gemini-3.1-pro", 37: "gemini-3.1-pro",
        18: "gemini-3-flash-preview", 47: "gemini-3-flash-preview",
        20: "gemini-3.5-flash", 132: "gemini-3.5-flash", 133: "gemini-3.5-flash", 187: "gemini-3.5-flash",
        26: "claude-opus-4-6",
        35: "claude-sonnet-4-6",
        50: "gemini-3.1-flash-lite",
        71: "gemini-3.6-flash", 72: "gemini-3.6-flash", 73: "gemini-3.6-flash",
        298: "gemini-3.7-flash", 299: "gemini-3.7-flash", 300: "gemini-3.7-flash",
        318: "gemini-3.8-flash", 319: "gemini-3.8-flash", 320: "gemini-3.8-flash",
        417: "gemini-4-argon", 418: "gemini-4-argon", 419: "gemini-4-argon",
    ]

    /// 早期版本直接写的模型编号。
    private static let legacyModelIDs: [Int: String] = [
        246: "gemini-2.5-pro",
        312: "gemini-2.5-flash", 313: "gemini-2.5-flash", 329: "gemini-2.5-flash",
        330: "gemini-2.5-flash-lite",
        281: "claude-sonnet-4", 282: "claude-sonnet-4",
        290: "claude-opus-4", 291: "claude-opus-4",
        333: "claude-sonnet-4-5", 334: "claude-sonnet-4-5",
        340: "claude-haiku-4-5", 341: "claude-haiku-4-5",
        342: "gpt-oss-120b",
    ]

    // MARK: - SQLite

    /// 只读打开并在一个读快照里完成全部查询。App 退出后 WAL 附属文件被删时，
    /// 系统 SQLite 的只读连接会报 SQLITE_CANTOPEN，此时没有写入方，改用 immutable 重读。
    private static func withDatabase(_ url: URL, body: (OpaquePointer) throws -> Void) throws {
        do {
            try withDatabase(url, immutable: false, body: body)
        } catch let failure as ReadFailure
            where failure.code.map({ $0 & 0xff }) == SQLITE_CANTOPEN
            && !FileManager.default.fileExists(atPath: url.path + "-wal")
            && !FileManager.default.fileExists(atPath: url.path + "-shm") {
            try withDatabase(url, immutable: true, body: body)
        }
    }

    private static func withDatabase(_ url: URL, immutable: Bool, body: (OpaquePointer) throws -> Void) throws {
        var opened: OpaquePointer?
        let filename = immutable ? "\(url.absoluteURL.absoluteString)?immutable=1" : url.path
        let flags = immutable ? SQLITE_OPEN_READONLY | SQLITE_OPEN_URI : SQLITE_OPEN_READONLY
        let openResult = sqlite3_open_v2(filename, &opened, flags, nil)
        guard openResult == SQLITE_OK, let db = opened else {
            if let opened { sqlite3_close(opened) }
            throw ReadFailure(detail: "database could not be opened", code: openResult)
        }
        defer { sqlite3_close(db) }
        sqlite3_busy_timeout(db, 2000)
        guard sqlite3_exec(db, "BEGIN", nil, nil, nil) == SQLITE_OK else {
            throw ReadFailure(detail: String(cString: sqlite3_errmsg(db)), code: sqlite3_errcode(db))
        }
        defer { sqlite3_exec(db, "ROLLBACK", nil, nil, nil) }
        try body(db)
    }

    private static func tableNames(_ db: OpaquePointer) throws -> Set<String> {
        var result: Set<String> = []
        try rows(db, sql: "SELECT name FROM sqlite_master WHERE type = 'table'") { stmt in
            if let name = columnText(stmt, 0) { result.insert(name) }
        }
        return result
    }

    private static func columns(_ db: OpaquePointer, table: String) throws -> Set<String> {
        var result: Set<String> = []
        try rows(db, sql: "PRAGMA table_info(\(table))") { stmt in
            if let name = columnText(stmt, 1) { result.insert(name) }
        }
        return result
    }

    private static func rows(_ db: OpaquePointer, sql: String, body: (OpaquePointer) throws -> Void) throws {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else {
            throw ReadFailure(detail: String(cString: sqlite3_errmsg(db)), code: sqlite3_errcode(db))
        }
        defer { sqlite3_finalize(stmt) }
        var status = sqlite3_step(stmt)
        while status == SQLITE_ROW {
            try autoreleasepool { try body(stmt) }
            status = sqlite3_step(stmt)
        }
        guard status == SQLITE_DONE else {
            throw ReadFailure(detail: String(cString: sqlite3_errmsg(db)), code: sqlite3_errcode(db))
        }
    }

    private static func columnText(_ stmt: OpaquePointer, _ index: Int32) -> String? {
        guard let c = sqlite3_column_text(stmt, index) else { return nil }
        return String(cString: c)
    }

    private static func columnBlob(_ stmt: OpaquePointer, _ index: Int32) -> [UInt8]? {
        let count = Int(sqlite3_column_bytes(stmt, index))
        guard count > 0, let pointer = sqlite3_column_blob(stmt, index) else { return nil }
        return Array(UnsafeRawBufferPointer(start: pointer, count: count))
    }

    // MARK: - Protobuf

    /// 不依赖 schema 的 protobuf 读取，只区分 varint 与长度分隔字段。
    nonisolated enum Proto {
        nonisolated enum Value {
            case varint(UInt64)
            case bytes([UInt8])
            case fixed
        }

        nonisolated struct Field {
            let number: Int
            let value: Value
        }

        /// 结构不合法时返回 nil。
        static func fields(_ data: [UInt8]) -> [Field]? {
            var fields: [Field] = []
            var index = 0
            while index < data.count {
                guard let key = varint(data, &index) else { return nil }
                let number = Int(clamping: key >> 3)
                guard number > 0 else { return nil }
                switch key & 7 {
                case 0:
                    guard let value = varint(data, &index) else { return nil }
                    fields.append(Field(number: number, value: .varint(value)))
                case 1:
                    guard data.count - index >= 8 else { return nil }
                    index += 8
                    fields.append(Field(number: number, value: .fixed))
                case 2:
                    guard let length = varint(data, &index), length <= UInt64(data.count - index) else { return nil }
                    let end = index + Int(length)
                    fields.append(Field(number: number, value: .bytes(Array(data[index..<end]))))
                    index = end
                case 5:
                    guard data.count - index >= 4 else { return nil }
                    index += 4
                    fields.append(Field(number: number, value: .fixed))
                default:
                    return nil
                }
            }
            return fields
        }

        private static func varint(_ data: [UInt8], _ index: inout Int) -> UInt64? {
            var result: UInt64 = 0
            var shift: UInt64 = 0
            while index < data.count, shift < 64 {
                let byte = data[index]
                index += 1
                result |= UInt64(byte & 0x7f) << shift
                if byte < 0x80 { return result }
                shift += 7
            }
            return nil
        }
    }
}

nonisolated extension Array where Element == AntigravityScanner.Proto.Field {
    func varint(_ number: Int) -> UInt64? {
        for field in self where field.number == number {
            if case .varint(let value) = field.value { return value }
        }
        return nil
    }

    func bytes(_ number: Int) -> [UInt8]? {
        for field in self where field.number == number {
            if case .bytes(let value) = field.value { return value }
        }
        return nil
    }

    func allBytes(_ number: Int) -> [[UInt8]] {
        compactMap { field in
            guard field.number == number, case .bytes(let value) = field.value else { return nil }
            return value
        }
    }

    func message(_ number: Int) -> [AntigravityScanner.Proto.Field]? {
        bytes(number).flatMap(AntigravityScanner.Proto.fields)
    }

    func text(_ number: Int) -> String? {
        guard let bytes = bytes(number), let text = String(bytes: bytes, encoding: .utf8) else { return nil }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
