import Foundation
import os

// MARK: - 级别与分类

nonisolated enum AppLogLevel: Int, Sendable, Comparable {
    case debug = 0
    case info
    case warn
    case error

    static func < (lhs: AppLogLevel, rhs: AppLogLevel) -> Bool { lhs.rawValue < rhs.rawValue }

    /// 固定 5 字宽，日志文件里级别列对齐，方便 grep 与肉眼扫。
    var label: String {
        switch self {
        case .debug: return "DEBUG"
        case .info: return "INFO "
        case .warn: return "WARN "
        case .error: return "ERROR"
        }
    }

    var osLogType: OSLogType {
        switch self {
        case .debug: return .debug
        case .info: return .info
        case .warn: return .default
        case .error: return .error
        }
    }
}

/// 与既有 `print` 前缀一一对应，收敛成固定集合：既作 OSLog category，也作文件里的分类列。
nonisolated enum AppLogCategory: String, Sendable, CaseIterable {
    /// 生命周期、调度、服务状态、更新检查
    case app
    case credentials
    case quota
    case usage
    case pricing
    case persistence
}

// MARK: - AppLog

/// 全局日志门面。见 `docs/草案-诊断日志-设计方案.md` §3。
///
/// 调用点横跨 `@MainActor`（AppState / UsageService）、带锁的 `nonisolated` 类
/// （PricingCatalogStore）与 `actor`（QuotaPersistenceCoordinator），所以这里必须是
/// `nonisolated` + 线程安全 + **同步返回**：加一个 `await` 就得改掉所有调用点的上下文。
///
/// 双输出端：
/// - 文件 `~/Library/Logs/CCBar/ccbar.log`，是导出诊断包的唯一来源。
/// - unified log（`os.Logger`），让开发者在自己机器上能 `log stream` 实时看。
///
/// 脱敏责任在**入口**（调用点 + `Redact.scrub`），不在 OSLog 的 privacy 标注；
/// 因此写 unified log 时统一标 `.public`，否则用户导出的日志全是 `<private>`，没有价值。
nonisolated final class AppLog: @unchecked Sendable {
    static let shared = AppLog()

    // MARK: 调用入口

    static func debug(_ category: AppLogCategory, _ message: @autoclosure () -> String) {
        shared.write(.debug, category, message)
    }

    static func info(_ category: AppLogCategory, _ message: @autoclosure () -> String) {
        shared.write(.info, category, message)
    }

    static func warn(_ category: AppLogCategory, _ message: @autoclosure () -> String) {
        shared.write(.warn, category, message)
    }

    static func error(_ category: AppLogCategory, _ message: @autoclosure () -> String) {
        shared.write(.error, category, message)
    }

    /// 级别在运行时才定的调用点用这个（例如整机快照里同一段逻辑既可能是正常值也可能是失败）。
    static func log(
        _ level: AppLogLevel,
        _ category: AppLogCategory,
        _ message: @autoclosure () -> String
    ) {
        shared.write(level, category, message)
    }

    // MARK: 配置

    static let verboseLoggingDefaultsKey = "ccbar.settings.verboseLogging"

    /// 由 `SettingsStore.verboseLogging` 的 didSet 推进来。关闭时 `debug` 既不落盘也不进 unified log。
    func setVerbose(_ enabled: Bool) {
        state.withLock { $0.minimumLevel = enabled ? .debug : .info }
    }

    // MARK: 落盘位置

    static let directoryURL: URL = {
        let library = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Library", isDirectory: true)
        return library
            .appendingPathComponent("Logs", isDirectory: true)
            .appendingPathComponent("CCBar", isDirectory: true)
    }()

    static let currentFileURL = directoryURL.appendingPathComponent("ccbar.log", isDirectory: false)

    /// 当前文件 + 轮转文件，按新到旧。导出诊断包时按这个顺序收集。
    static var allFileURLs: [URL] {
        [currentFileURL] + (1...rotationCount).map { rotatedFileURL(index: $0) }
    }

    static func rotatedFileURL(index: Int) -> URL {
        directoryURL.appendingPathComponent("ccbar.log.\(index)", isDirectory: false)
    }

    // MARK: 时间戳

    /// 日志行与诊断摘要共用一种绝对时间戳。用户和开发者常不在同一时区，
    /// 带时区偏移才能和用户描述的"大概几点出的问题"对上。
    /// `ISO8601DateFormatter` 的 formatting 路径线程安全，可直接共享。
    static func timestamp(_ date: Date) -> String {
        isoFormatter.string(from: date)
    }

    private static let isoFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        formatter.timeZone = .current
        return formatter
    }()

    // MARK: 内部状态

    private struct State {
        var buffer: [String] = []
        var lastFlushAt = Date.distantPast
        var minimumLevel: AppLogLevel = .info
        /// 已经有一次延迟落盘在排队。没有它，一批同时写入的日志里只有第一条会
        /// 立即落盘，其余留在内存等下一次写入触发——崩溃时丢的正是最关键那几行。
        var flushScheduled = false
    }

    /// 一次 `write` 之后要做什么。判定在锁内完成，真正的 I/O 在锁外派发。
    private enum FlushAction {
        case none
        case now([String])
        case schedule
    }

    private let state: OSAllocatedUnfairLock<State>
    private let queue = DispatchQueue(label: "com.cc-bar.applog", qos: .utility)
    private let loggers: [AppLogCategory: Logger]

    /// 单文件轮转阈值与保留份数：2 MB × (1 + 3) ≈ 8 MB 上限。
    /// 1 分钟刷新档约 1.4 MB/天，够覆盖"刚出问题"之后的几天。
    private static let maxFileBytes = 2 * 1024 * 1024
    private static let rotationCount = 3
    /// 缓冲策略：攒够 64 条或距上次落盘超过 5 秒才写一次，避免每条日志一次文件 I/O。
    private static let flushThreshold = 64
    private static let flushInterval: TimeInterval = 5
    /// 单行上限。整机额度快照一行可到 200+ 字符，留够余量；
    /// `Redact.message` 用于错误文本，仍是更紧的 300。
    private static let maxLineLength = 600

    private init() {
        var built: [AppLogCategory: Logger] = [:]
        for category in AppLogCategory.allCases {
            built[category] = Logger(subsystem: "com.cc-bar", category: category.rawValue)
        }
        loggers = built

        let verbose = UserDefaults.standard.bool(forKey: Self.verboseLoggingDefaultsKey)
        state = OSAllocatedUnfairLock(initialState: State(minimumLevel: verbose ? .debug : .info))
    }

    // MARK: 写入

    private func write(
        _ level: AppLogLevel,
        _ category: AppLogCategory,
        _ message: () -> String
    ) {
        guard level >= state.withLock({ $0.minimumLevel }) else { return }

        // 出口兜底清洗：即便调用点漏了 Redact，也不会有原始密钥 / 邮箱落盘。
        let text = Redact.scrub(Redact.oneLine(message(), limit: Self.maxLineLength))
        loggers[category]?.log(level: level.osLogType, "\(text, privacy: .public)")

        let action: FlushAction = state.withLock { current in
            current.buffer.append(
                "\(Self.timestamp(Date()))  \(level.label)  "
                    + category.rawValue.padding(toLength: 12, withPad: " ", startingAt: 0)
                    + text
            )
            let now = Date()
            let due = current.buffer.count >= Self.flushThreshold
                || now.timeIntervalSince(current.lastFlushAt) >= Self.flushInterval
            if due {
                current.lastFlushAt = now
                current.flushScheduled = false
                let drained = current.buffer
                current.buffer.removeAll(keepingCapacity: true)
                return .now(drained)
            }
            guard !current.flushScheduled else { return .none }
            current.flushScheduled = true
            return .schedule
        }

        switch action {
        case .none:
            break
        case .now(let lines):
            queue.async { [weak self] in self?.append(lines) }
        case .schedule:
            queue.asyncAfter(deadline: .now() + Self.flushInterval) { [weak self] in
                self?.drainScheduled()
            }
        }
    }

    /// 延迟落盘兜底，只在 `queue` 上执行。
    private func drainScheduled() {
        let pending: [String] = state.withLock { current in
            current.flushScheduled = false
            guard !current.buffer.isEmpty else { return [] }
            current.lastFlushAt = Date()
            let drained = current.buffer
            current.buffer.removeAll(keepingCapacity: true)
            return drained
        }
        guard !pending.isEmpty else { return }
        append(pending)
    }

    /// 同步把缓冲里剩下的内容写完。导出诊断包前与 App 退出前调用，
    /// 否则最近 5 秒内最关键的那几行可能还没落盘。
    func flushNow() {
        let pending: [String] = state.withLock { current in
            current.lastFlushAt = Date()
            current.flushScheduled = false
            let drained = current.buffer
            current.buffer.removeAll(keepingCapacity: true)
            return drained
        }
        queue.sync {
            if !pending.isEmpty { self.append(pending) }
        }
    }

    /// 只在 `queue` 上执行，串行，不会与轮转竞争。
    private func append(_ lines: [String]) {
        let text = lines.joined(separator: "\n") + "\n"
        guard let data = text.data(using: .utf8) else { return }
        let fm = FileManager.default
        try? fm.createDirectory(at: Self.directoryURL, withIntermediateDirectories: true)
        let url = Self.currentFileURL
        if fm.fileExists(atPath: url.path), let handle = try? FileHandle(forWritingTo: url) {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: data)
        } else {
            try? data.write(to: url, options: .atomic)
        }
        rotateIfNeeded()
    }

    private func rotateIfNeeded() {
        let fm = FileManager.default
        let url = Self.currentFileURL
        guard
            let attrs = try? fm.attributesOfItem(atPath: url.path),
            let size = attrs[.size] as? NSNumber,
            size.intValue >= Self.maxFileBytes
        else { return }

        // 最旧一份直接删掉，其余依次后移，最后把当前文件降级成 .1。
        try? fm.removeItem(at: Self.rotatedFileURL(index: Self.rotationCount))
        for index in stride(from: Self.rotationCount - 1, through: 1, by: -1) {
            let from = Self.rotatedFileURL(index: index)
            guard fm.fileExists(atPath: from.path) else { continue }
            try? fm.moveItem(at: from, to: Self.rotatedFileURL(index: index + 1))
        }
        try? fm.moveItem(at: url, to: Self.rotatedFileURL(index: 1))
    }
}
