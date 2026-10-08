import Foundation

/// 一次本地用量提交的完整性状态。
///
/// 本轮只允许两级：`complete` 与「有历史但没有可信进度」。
/// 后者禁止用空状态的全量结果覆盖或追加到历史之上，必须走一次受限核对（见 UsageService）。
nonisolated enum UsageSnapshotIntegrity: String, Sendable, Codable, Equatable {
    case complete
    /// 日 / 对话 / 周期历史可用，但缺少与它同代、可继续续扫的扫描进度。
    case historyWithoutProgress
}

/// 降级原因。只保存稳定的原因码，UI 文案在展示层翻译，不在存储里放自然语言。
nonisolated enum UsageSnapshotDegradeReason: String, Sendable, Codable, Equatable {
    case scanStateMissing
    case scanStateInvalid
    case scanStateGenerationMismatch
    case conversationGenerationMismatch
    case conversationUnsupportedVersion
    case cycleGenerationMismatch
    case cycleUnsupportedVersion
    case dshGenerationMismatch
    case dshUnsupportedVersion
    case dshUnavailable
    case legacyDayUnusable
    case legacyDayUnsupportedVersion
    case legacyConversationUnusable
    case legacyConversationUnsupportedVersion
    case legacyCycleUnusable
    case legacyCycleUnsupportedVersion
}

/// 一个完整的本地用量提交。
///
/// 为什么是「一份文件一份提交」：日 / 对话 / 周期三份 rollup、扫描进度与 DSH 贡献
/// 之间存在代次和进度耦合，分文件 `.atomic` 写不构成一笔整体提交。把 Home 放在同一个
/// envelope 里，进程在任何两次文件替换之间退出，至少还剩一份完整提交。
nonisolated struct UsageSnapshot: Sendable, Codable {
    /// 只描述 envelope 自身布局。内层 payload 的版本各自校验：任一层不是当前版本都视为
    /// 「不支持」而不是「空」，避免把无法解释的文件伪装成首装。
    static let currentVersion = 1

    var version: Int = Self.currentVersion
    /// 提交标识 = 三个 rollup / 扫描进度 / DSH 共用的代次。
    var snapshotID: String = ""
    var createdAt: Date = .distantPast
    var committedAt: Date = .distantPast
    var integrity: UsageSnapshotIntegrity = .complete
    var degradeReasons: [UsageSnapshotDegradeReason] = []
    /// false 表示 `scanState` 只是占位、不可用于续扫（受限恢复）。
    var hasScanProgress: Bool = true
    /// true 表示主历史里有 DSH 分区，但逐会话贡献已不可用：此时既不能增量也不能重建 DSH，
    /// 只能原样保留 DSH 分区并明确报告，避免把空贡献归并回旧分区。
    var dshHistoryFrozen: Bool = false
    var scanState: ScanState = ScanState()
    var usageRollup: UsageRollupPayload = UsageRollupPayload()
    var conversationRollup: ConversationRollupPayload = ConversationRollupPayload()
    var cycleRollup: CycleUsageRollupPayload = CycleUsageRollupPayload()
    var dshContributions: DshContributionPayload = DshContributionPayload()
    /// 可选字段兼容旧 envelope / payload；与桶和进度原子提交，不使旧快照失效。
    var codexModelIdentityMigration: CodexModelIdentityMigrationState?
    /// 按对话记录的已计入消息 ID（`UsageMessageLedger`）。旧快照没有；版本不认识时按没有处理。
    var messageLedger: UsageMessageLedgerPayload?
    /// 现有历史对应的统计规则与价格（`UsageRebuildBasis`）。nil 表示还没有建立，启动后自动重建一次。
    var rebuildBasis: UsageRebuildBasis?

    /// 结构性不变量。校验失败一律不写盘、不切换内存，避免「JSON 能解码」被当成可用。
    func validateStructure() throws {
        guard version == Self.currentVersion else {
            throw UsageSnapshotStructureError.unsupportedEnvelopeVersion(version)
        }
        if let migration = codexModelIdentityMigration,
           migration.version != CodexModelIdentityMigrationState.currentVersion {
            throw UsageSnapshotStructureError.unsupportedInnerVersion("codexModelIdentity", migration.version)
        }
        guard !snapshotID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw UsageSnapshotStructureError.missingSnapshotID
        }
        guard usageRollup.version == UsageRollupPayload.currentVersion else {
            throw UsageSnapshotStructureError.unsupportedInnerVersion("usageRollup", usageRollup.version)
        }
        guard conversationRollup.version == ConversationRollupPayload.currentVersion else {
            throw UsageSnapshotStructureError.unsupportedInnerVersion("conversationRollup", conversationRollup.version)
        }
        guard cycleRollup.version == CycleUsageRollupPayload.currentVersion else {
            throw UsageSnapshotStructureError.unsupportedInnerVersion("cycleRollup", cycleRollup.version)
        }
        guard dshContributions.version == DshContributionPayload.currentVersion else {
            throw UsageSnapshotStructureError.unsupportedInnerVersion("dsh", dshContributions.version)
        }
        guard scanState.version == ScanState.currentVersion else {
            throw UsageSnapshotStructureError.unsupportedInnerVersion("scanState", scanState.version)
        }
        guard usageRollup.generationID == snapshotID,
              conversationRollup.generationID == snapshotID
        else {
            throw UsageSnapshotStructureError.generationMismatch("usage/conversation")
        }
        // 周期缓存允许为空（等待重建），但一旦带数据就必须是同代。
        if !cycleRollup.generationID.isEmpty, cycleRollup.generationID != snapshotID {
            throw UsageSnapshotStructureError.generationMismatch("cycle")
        }
        if !dshContributions.generationID.isEmpty, dshContributions.generationID != snapshotID {
            throw UsageSnapshotStructureError.generationMismatch("dsh")
        }
        if hasScanProgress {
            guard scanState.generationID == snapshotID else {
                throw UsageSnapshotStructureError.generationMismatch("scanState")
            }
        } else {
            // 受限恢复不允许携带任何看起来像进度的状态（包括 generation），
            // 否则下一次启动会把空状态当成可续扫进度。
            guard scanState.generationID.isEmpty,
                  scanState.claude.isEmpty, scanState.codex.isEmpty, scanState.pi.isEmpty,
                  scanState.dsh.isEmpty, scanState.opencode == nil,
                  scanState.claudeSeenMessageIds.isEmpty, scanState.codexSeenTokenIds.isEmpty,
                  scanState.piSeenEntryIds.isEmpty
            else {
                throw UsageSnapshotStructureError.progressFlagMismatch
            }
            guard integrity == .historyWithoutProgress else {
                throw UsageSnapshotStructureError.progressFlagMismatch
            }
        }
        if integrity == .historyWithoutProgress, hasScanProgress {
            throw UsageSnapshotStructureError.progressFlagMismatch
        }
        if dshHistoryFrozen {
            guard dshContributions.generationID.isEmpty,
                  dshContributions.contributions.isEmpty
            else {
                throw UsageSnapshotStructureError.frozenDshCarriesContributions
            }
        }
    }
}

nonisolated enum UsageSnapshotStructureError: Error, CustomStringConvertible, Equatable {
    case unsupportedEnvelopeVersion(Int)
    case unsupportedInnerVersion(String, Int)
    case missingSnapshotID
    case generationMismatch(String)
    case progressFlagMismatch
    case frozenDshCarriesContributions

    var description: String {
        switch self {
        case .unsupportedEnvelopeVersion(let version):
            return "unsupported envelope version \(version)"
        case .unsupportedInnerVersion(let name, let version):
            return "unsupported \(name) version \(version)"
        case .missingSnapshotID:
            return "missing snapshot id"
        case .generationMismatch(let part):
            return "generation mismatch in \(part)"
        case .progressFlagMismatch:
            return "scan progress flag inconsistent with scan state"
        case .frozenDshCarriesContributions:
            return "frozen dsh partition still carries contributions"
        }
    }
}

private nonisolated struct UsageSnapshotVersionProbe: Decodable {
    struct Payload: Decodable { let version: Int }
    let version: Int
    var usageRollup: Payload?
    var conversationRollup: Payload?
    var cycleRollup: Payload?
    var scanState: Payload?
    var dshContributions: Payload?
}

nonisolated enum UsageSnapshotInvalidReason: Sendable, Equatable, CustomStringConvertible {
    case unreadable(String)
    case decodeFailed(String)
    /// 版本不受支持：不得覆盖原文件，也不得当成「空」继续写。
    case unsupportedVersion(Int)
    case inconsistent(String)
    case unsupportedInnerVersion(String, Int)

    var isUnsupported: Bool {
        switch self {
        case .unsupportedVersion, .unsupportedInnerVersion: return true
        default: return false
        }
    }

    var description: String {
        switch self {
        case .unreadable(let detail): return "unreadable: \(detail)"
        case .decodeFailed(let detail): return "decode failed: \(detail)"
        case .unsupportedVersion(let version): return "unsupported version \(version)"
        case .inconsistent(let detail): return "inconsistent: \(detail)"
        case .unsupportedInnerVersion(let name, let version): return "unsupported \(name) version \(version)"
        }
    }
}

nonisolated enum UsageSnapshotLoadResult: Sendable {
    case missing
    case valid(UsageSnapshot)
    case invalid(UsageSnapshotInvalidReason)

    var snapshot: UsageSnapshot? {
        if case .valid(let snapshot) = self { return snapshot }
        return nil
    }

    var invalidReason: UsageSnapshotInvalidReason? {
        if case .invalid(let reason) = self { return reason }
        return nil
    }
}

/// 当前 / 上一份快照的两级保留存储。
///
/// 提交协议（对应执行计划 §4.1）：
/// 1. 编码候选并做结构校验，失败时当前内存与磁盘都不切换。
/// 2. 若存在**已验证有效**的 current，把它按原始字节原子写为 previous；
///    损坏、错代或尚未提交的候选不会被轮转成备份。
/// 3. 原子替换 current，这是本次提交的切换点；previous 写失败则终止本次提交。
nonisolated final class UsageSnapshotStore: @unchecked Sendable {
    enum FaultPoint: String, Sendable, CaseIterable {
        case beforeEncode
        case afterEncode
        case beforePreviousRotation
        case afterPreviousRotation
        case beforeCurrentReplace
        case afterCurrentReplace
    }

    /// 测试注入的故障点。生产路径保持空集合，`check` 只是一次加锁读。
    /// 计数按点独立：`fail(at:occurrence:)` 只让第 N 次命中抛错，方便验证「重试成功后只提交一次」。
    final class FaultInjector: @unchecked Sendable {
        private let lock = NSLock()
        private var points: [FaultPoint: Int] = [:]
        private var seen: [FaultPoint: Int] = [:]

        func fail(at point: FaultPoint, occurrence: Int = 1) {
            lock.lock()
            points[point] = occurrence
            seen[point] = 0
            lock.unlock()
        }

        func clear() {
            lock.lock()
            points.removeAll()
            seen.removeAll()
            lock.unlock()
        }

        func shouldFail(_ point: FaultPoint) -> Bool {
            lock.lock()
            defer { lock.unlock() }
            guard let occurrence = points[point] else { return false }
            let count = (seen[point] ?? 0) + 1
            seen[point] = count
            guard count == occurrence else { return false }
            points.removeValue(forKey: point)
            return true
        }
    }

    /// 提交计数（测试用来证明「无变化不重写大快照」，不进 UI）。
    final class CommitStats: @unchecked Sendable {
        private let lock = NSLock()
        private var encodes = 0
        private var commits = 0

        func recordEncode() {
            lock.lock()
            encodes += 1
            lock.unlock()
        }

        func recordCommit() {
            lock.lock()
            commits += 1
            lock.unlock()
        }

        var encodeCount: Int {
            lock.lock()
            defer { lock.unlock() }
            return encodes
        }

        var commitCount: Int {
            lock.lock()
            defer { lock.unlock() }
            return commits
        }
    }

    struct InjectedFault: Error, CustomStringConvertible {
        var point: FaultPoint
        var description: String { "injected fault at \(point.rawValue)" }
    }

    static let production = UsageSnapshotStore()

    private static let bundleDirectory = "CCBar"
    private static let historyDirectoryName = "usage-history"
    private static let currentFileName = "current.json"
    private static let previousFileName = "previous.json"
    private static let quarantineDirectoryName = "quarantine"

    /// nil 走生产路径；测试必须注入临时目录，避免覆盖用户真机历史。
    private let directoryOverride: URL?
    let faults: FaultInjector
    let stats: CommitStats

    init(directory: URL? = nil, faults: FaultInjector = FaultInjector(), stats: CommitStats = CommitStats()) {
        self.directoryOverride = directory
        self.faults = faults
        self.stats = stats
    }

    var directory: URL {
        if let directoryOverride { return directoryOverride }
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Library/Application Support", isDirectory: true)
        return support
            .appendingPathComponent(Self.bundleDirectory, isDirectory: true)
            .appendingPathComponent(Self.historyDirectoryName, isDirectory: true)
    }

    var currentFileURL: URL { directory.appendingPathComponent(Self.currentFileName, isDirectory: false) }
    var previousFileURL: URL { directory.appendingPathComponent(Self.previousFileName, isDirectory: false) }

    /// 一旦开始使用新存储，文件丢失也不能重新导入冻结的旧缓存。
    var establishedFileURL: URL { directory.appendingPathComponent("established") }

    var hasHistoryEvidence: Bool {
        [establishedFileURL, currentFileURL, previousFileURL,
         directory.appendingPathComponent(Self.quarantineDirectoryName)].contains {
            FileManager.default.fileExists(atPath: $0.path)
        }
    }

    func loadCurrent() -> UsageSnapshotLoadResult {
        load(at: currentFileURL)
    }

    func loadPrevious() -> UsageSnapshotLoadResult {
        load(at: previousFileURL)
    }

    private func load(at url: URL) -> UsageSnapshotLoadResult {
        guard FileManager.default.fileExists(atPath: url.path) else { return .missing }
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            return .invalid(.unreadable(String(describing: error)))
        }
        return Self.decode(data)
    }

    /// 独立的解码入口：测试与新实例恢复都用它，保证「重启后能读到什么」只取决于字节。
    nonisolated static func decode(_ data: Data) -> UsageSnapshotLoadResult {
        // 先只取版本号：旧 / 新版本格式即使能结构化解码也不能当成本版本数据使用。
        guard let probe = try? JSONDecoder().decode(UsageSnapshotVersionProbe.self, from: data) else {
            return .invalid(.decodeFailed("not a usage snapshot"))
        }
        guard probe.version == UsageSnapshot.currentVersion else {
            return .invalid(.unsupportedVersion(probe.version))
        }
        let versions: [(String, Int?, Int)] = [
            ("usageRollup", probe.usageRollup?.version, UsageRollupPayload.currentVersion),
            ("conversationRollup", probe.conversationRollup?.version, ConversationRollupPayload.currentVersion),
            ("cycleRollup", probe.cycleRollup?.version, CycleUsageRollupPayload.currentVersion),
            ("scanState", probe.scanState?.version, ScanState.currentVersion),
            ("dsh", probe.dshContributions?.version, DshContributionPayload.currentVersion),
        ]
        for (name, version, supported) in versions {
            if let version, version != supported {
                return .invalid(.unsupportedInnerVersion(name, version))
            }
        }
        let snapshot: UsageSnapshot
        do {
            snapshot = try JSONDecoder().decode(UsageSnapshot.self, from: data)
        } catch {
            return .invalid(.decodeFailed(String(describing: error)))
        }
        do {
            try snapshot.validateStructure()
        } catch UsageSnapshotStructureError.unsupportedInnerVersion(let name, let version) {
            return .invalid(.unsupportedInnerVersion(name, version))
        } catch {
            return .invalid(.inconsistent(String(describing: error)))
        }
        return .valid(snapshot)
    }

    func commit(_ snapshot: UsageSnapshot) throws {
        try snapshot.validateStructure()
        if faults.shouldFail(.beforeEncode) { throw InjectedFault(point: .beforeEncode) }
        stats.recordEncode()
        let data = try JSONEncoder().encode(snapshot)
        if faults.shouldFail(.afterEncode) { throw InjectedFault(point: .afterEncode) }

        let fileManager = FileManager.default
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)

        // 轮转前先确认 current 是完整的旧提交：损坏 / 错代 / 不支持的文件不能变成 previous。
        if fileManager.fileExists(atPath: currentFileURL.path) {
            let currentData: Data
            do {
                currentData = try Data(contentsOf: currentFileURL)
            } catch {
                throw UsageSnapshotStoreError.currentUnreadable(String(describing: error))
            }
            if case .invalid(let reason) = Self.decode(currentData) {
                throw UsageSnapshotStoreError.currentNotCommittable(reason)
            }
            if faults.shouldFail(.beforePreviousRotation) { throw InjectedFault(point: .beforePreviousRotation) }
            try currentData.write(to: previousFileURL, options: [.atomic])
            if faults.shouldFail(.afterPreviousRotation) { throw InjectedFault(point: .afterPreviousRotation) }
        }

        if faults.shouldFail(.beforeCurrentReplace) { throw InjectedFault(point: .beforeCurrentReplace) }
        // 在首次替换前保存标记。此后若写入失败且快照全部丢失，保守停止，不能静默重迁移。
        if !fileManager.fileExists(atPath: establishedFileURL.path) {
            try Data("1\n".utf8).write(to: establishedFileURL, options: [.atomic])
        }
        try data.write(to: currentFileURL, options: [.atomic])
        stats.recordCommit()
        if faults.shouldFail(.afterCurrentReplace) { throw InjectedFault(point: .afterCurrentReplace) }
    }

    /// 把无法解释的 current 移到 quarantine/，避免后续提交覆盖掉故障证据。
    /// 只在调用方判定要回退到 previous 时调用；返回隔离后的文件位置。
    @discardableResult
    func quarantineCurrent() -> URL? {
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: currentFileURL.path) else { return nil }
        let directoryURL = directory.appendingPathComponent(Self.quarantineDirectoryName, isDirectory: true)
        do {
            try fileManager.createDirectory(at: directoryURL, withIntermediateDirectories: true)
            let stamp = ISO8601DateFormatter().string(from: Date())
                .replacingOccurrences(of: ":", with: "-")
            var destination = directoryURL.appendingPathComponent("current-\(stamp).json", isDirectory: false)
            var suffix = 1
            while fileManager.fileExists(atPath: destination.path) {
                destination = directoryURL.appendingPathComponent("current-\(stamp)-\(suffix).json", isDirectory: false)
                suffix += 1
            }
            try fileManager.moveItem(at: currentFileURL, to: destination)
            return destination
        } catch {
            return nil
        }
    }

    /// 只读诊断：不需要解码即可判断某个文件是否存在。
    func fileExists(at url: URL) -> Bool {
        FileManager.default.fileExists(atPath: url.path)
    }
}

nonisolated enum UsageSnapshotStoreError: Error, CustomStringConvertible {
    /// 当前文件无法解释且还没被隔离：拒绝轮转，等调用方处理。
    case currentNotCommittable(UsageSnapshotInvalidReason)
    case currentUnreadable(String)

    var description: String {
        switch self {
        case .currentNotCommittable(let reason):
            return "current snapshot is not committable (\(reason))"
        case .currentUnreadable(let detail):
            return "current snapshot unreadable: \(detail)"
        }
    }
}
