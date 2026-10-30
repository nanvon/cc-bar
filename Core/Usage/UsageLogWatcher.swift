import CoreServices
import Foundation
import os

/// FSEvents 回调跑在后台队列，用锁盒子承接，避免每个事件都往主 actor 跳一次。
/// 初值 true：stream 尚未起来时门控直接放行。
/// 刻意放在顶层而非嵌套进 `UsageLogWatcher`：嵌套类型会继承外层的 `@MainActor`
/// 隔离，而这个盒子必须能在 FSEvents 的后台回调里直接访问。
private final class UsageLogChangeFlag: Sendable {
    private let state = OSAllocatedUnfairLock(initialState: true)
    let matcher = UsageLogPathMatcher.standard()

    func mark() {
        state.withLock { $0 = true }
    }

    /// FSEvents 回调入口：只有本批事件里有用量日志相关的路径才置位。
    func handle(paths: [String], flags: [FSEventStreamEventFlags]) {
        guard matcher.shouldMark(paths: paths, flags: flags) else { return }
        mark()
    }

    /// 读取并清零。
    func consume() -> Bool {
        state.withLock { value in
            let current = value
            value = false
            return current
        }
    }

    func raise() {
        state.withLock { $0 = true }
    }
}

/// 判断 FSEvents 上报的路径是否属于扫描器实际读取的日志。
///
/// 监听仍落在 provider 顶层目录（子目录可能尚未创建），但顶层目录里大部分写入与用量无关
/// （设置、缓存、shell 快照、锁文件等）。尤其 SQLite 只读打开 `opencode.db` 也会改写同目录的
/// `-shm`：不过滤的话，CCBar 自己的每次扫描都会让下一轮门控放行，门控形同虚设。
nonisolated struct UsageLogPathMatcher: Sendable {
    /// 日志目录：路径等于它或位于其下即命中。
    let directories: [String]
    /// 精确文件路径。
    let files: Set<String>
    /// SQLite 库所在目录（Antigravity 每个对话一个库）：其下除 `-shm` 外的写入都算变化。
    var databaseDirectories: [String] = []

    static func standard(roots: UsageScanRoots = .production) -> UsageLogPathMatcher {
        let directories = [roots.claudeRoot] + roots.codexRoots + [roots.piRoot, roots.dshRoot]
            + roots.antigravityRoots.map { $0.appendingPathComponent("annotations", isDirectory: true) }
        // 只认数据库本体和 WAL；`-shm` 读者也会写，不代表有新数据。
        let database = roots.opencodeDatabaseURL
        let files = [
            database,
            database.deletingLastPathComponent()
                .appendingPathComponent(database.lastPathComponent + "-wal", isDirectory: false),
        ] + roots.antigravityRoots.flatMap { root in
            ["agyhub_summaries_proto.pb", "conversation_summaries.db", "conversation_summaries.db-wal"]
                .map { root.appendingPathComponent($0) }
        }
        // FSEvents 上报的是解析过符号链接的真实路径，两种写法都收下。
        func variants(_ urls: [URL]) -> [String] {
            Array(Set(urls.flatMap { [$0.path, $0.resolvingSymlinksInPath().path] }))
        }
        return UsageLogPathMatcher(
            directories: variants(directories),
            files: Set(variants(files)),
            databaseDirectories: variants(AntigravityScanner.conversationDirectories(roots: roots.antigravityRoots))
        )
    }

    func matches(_ path: String) -> Bool {
        if files.contains(path) { return true }
        if !path.hasSuffix("-shm"), databaseDirectories.contains(where: { path.hasPrefix($0 + "/") }) {
            return true
        }
        return directories.contains { path == $0 || path.hasPrefix($0 + "/") }
    }

    /// 事件被合并或丢弃、监听根被移动时无法确定具体路径，按有变化处理。
    func shouldMark(paths: [String], flags: [FSEventStreamEventFlags]) -> Bool {
        guard paths.count == flags.count else { return true }
        let uncertain = FSEventStreamEventFlags(
            kFSEventStreamEventFlagMustScanSubDirs
                | kFSEventStreamEventFlagUserDropped
                | kFSEventStreamEventFlagKernelDropped
                | kFSEventStreamEventFlagRootChanged
        )
        return zip(paths, flags).contains { path, flag in
            flag & uncertain != 0 || matches(path)
        }
    }
}

/// 本地日志目录的变化门控。
///
/// 周期用量扫描原本每轮都会递归枚举全部日志目录并逐文件取 mtime/size——本机实测
/// 2535 个 jsonl / 314 个目录，5 分钟一轮就是每天约 180 万次 stat，绝大多数轮次
/// 一个字节都没变。这里用 FSEvents 监听日志根目录，只有真的发生过写入才让那一轮
/// 扫描继续。
///
/// **失败一律退化成「每轮都扫」**：stream 起不来、路径不存在、事件漏报，都只会让
/// 门控多放行，不会让数据停更。另外无论有没有事件，超过 `maxSkipInterval` 必定
/// 强制扫一次兜底。
@MainActor
final class UsageLogWatcher {
    static let shared = UsageLogWatcher()

    /// 即使一个事件都没收到，也至少这么久做一次完整扫描。
    /// FSEvents 可能因权限、卷类型或事件合并而漏报，兜底保证数据不会停更。
    private static let maxSkipInterval: TimeInterval = 30 * 60

    /// 事件合并窗口。门控本身不需要低延迟（扫描周期是分钟级），
    /// 窗口给大一点可以把一次编码会话里的密集写入合并成很少的几次回调。
    private static let latency: CFTimeInterval = 2.0

    private let changeFlag = UsageLogChangeFlag()
    private let queue = DispatchQueue(label: "com.ccbar.usage-log-watcher", qos: .utility)
    private var stream: FSEventStreamRef?
    /// 已成功纳入监听的路径；用于判断是否有新出现的日志根需要重建 stream。
    private var watchedRoots: Set<String> = []
    private var lastScanStartedAt: Date?
    private var suspendedForTermination = false

    private init() {}

    /// 各扫描器的日志根。监听的是 provider 的顶层目录而不是精确的 sessions 子目录：
    /// 子目录可能尚未创建，而 FSEvents 只监听创建 stream 时已存在的路径。
    /// 顶层目录里的无关写入由 `UsageLogPathMatcher` 按文件路径过滤掉。
    private static func candidateRoots() -> [String] {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return [
            ".claude",
            ".codex",
            ".pi",
            ".local/share/opencode",
            // DSH：默认根 `~/.dsh/sessions`，这里监听顶层目录（sessions 可能尚未创建）。
            ".dsh",
            // Antigravity：`~/.gemini/antigravity*/conversations` 与 `~/.config/antigravity`。
            ".gemini",
            ".config/antigravity",
        ].map { home.appendingPathComponent($0, isDirectory: true).path }
    }

    /// 周期扫描的门控：返回 true 表示这一轮应该真的扫。
    /// 标记在扫描**开始前**清零，扫描期间产生的新事件会重新置位、由下一轮接手。
    func shouldScan(now: Date = Date()) -> Bool {
        guard !suspendedForTermination else { return false }
        startIfNeeded()
        let forced = lastScanStartedAt.map { now.timeIntervalSince($0) >= Self.maxSkipInterval } ?? true
        let changed = changeFlag.consume()
        guard changed || forced else { return false }
        lastScanStartedAt = now
        return true
    }

    /// 扫描留下了还没读完的内容（例如末尾仍在写的消息）：下一轮周期扫描不受门控跳过。
    func requestRescan() {
        changeFlag.raise()
    }

    func suspendForTermination() {
        suspendedForTermination = true
        stopStream()
    }

    func resumeAfterCancelledTermination() {
        suspendedForTermination = false
        changeFlag.raise()
        startIfNeeded()
    }

    // MARK: - FSEvents

    private func startIfNeeded() {
        let existing = Set(Self.candidateRoots().filter {
            FileManager.default.fileExists(atPath: $0)
        })
        guard !existing.isEmpty else {
            // 一个日志根都没有：没什么可监听的，门控保持放行由扫描器自己发现空目录。
            changeFlag.raise()
            return
        }
        // 已在监听且没有新出现的根 → 无需重建。
        if stream != nil, existing == watchedRoots { return }

        stopStream()
        // context 被 FSEventStreamCreate 拷贝，栈上的临时变量即可；
        // info 指向的盒子由本单例强持有，因此 retain/release 留空。
        var context = FSEventStreamContext(
            version: 0,
            info: Unmanaged.passUnretained(changeFlag).toOpaque(),
            retain: nil,
            release: nil,
            copyDescription: nil
        )

        let callback: FSEventStreamCallback = { _, info, count, eventPaths, eventFlags, _ in
            guard let info else { return }
            let sink = Unmanaged<UsageLogChangeFlag>.fromOpaque(info).takeUnretainedValue()
            // UseCFTypes：eventPaths 是 CFArray<CFString>。取不到路径时按有变化处理。
            guard let paths = unsafeBitCast(eventPaths, to: NSArray.self) as? [String] else {
                sink.mark()
                return
            }
            let flags = Array(UnsafeBufferPointer(start: eventFlags, count: count))
            sink.handle(paths: paths, flags: flags)
        }

        guard let created = FSEventStreamCreate(
            kCFAllocatorDefault,
            callback,
            &context,
            Array(existing) as CFArray,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
            Self.latency,
            // WatchRoot：日志根被整体移动/重建时收到通知，不至于一直盯着旧 inode。
            // FileEvents + UseCFTypes：逐文件上报路径，供 UsageLogPathMatcher 过滤无关写入。
            UInt32(
                kFSEventStreamCreateFlagWatchRoot
                    | kFSEventStreamCreateFlagFileEvents
                    | kFSEventStreamCreateFlagUseCFTypes
            )
        ) else {
            // 建流失败：保持放行，行为与没有门控时一致。
            changeFlag.raise()
            AppLog.warn(.usage, "FSEventStreamCreate failed; falling back to full scan each cycle")
            return
        }

        FSEventStreamSetDispatchQueue(created, queue)
        guard FSEventStreamStart(created) else {
            FSEventStreamInvalidate(created)
            FSEventStreamRelease(created)
            changeFlag.raise()
            AppLog.warn(.usage, "FSEventStreamStart failed; falling back to full scan each cycle")
            return
        }
        stream = created
        watchedRoots = existing
        // 建流之前发生的写入不会补发，先放行一轮把差量扫进来。
        changeFlag.raise()
    }

    private func stopStream() {
        guard let stream else { return }
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
        self.stream = nil
        watchedRoots = []
    }
}
