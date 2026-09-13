import AppKit
import Darwin
import Foundation

/// 「导出诊断日志」的产物构建。见 `docs/草案-诊断日志-设计方案.md` §6。
///
/// 产出 `CCBar-diagnostics-<时间戳>.zip`：`summary.txt` + 轮转日志文件。
/// 摘要与日志都过 `Redact`，不含 token、明文邮箱、对话内容、项目名。
/// **不做任何自动上报**——文件只落在本机临时目录，发不发、发给谁由用户决定。
@MainActor
enum DiagnosticsBundle {
    enum ExportError: LocalizedError {
        case archiveFailed(String)

        var errorDescription: String? {
            switch self {
            case .archiveFailed(let detail):
                return "Failed to create the diagnostics archive: \(detail)"
            }
        }
    }

    /// 生成诊断包并返回 zip 路径。调用方负责在 Finder 中显示。
    ///
    /// 摘要分两段生成：运行时状态只读内存，在 MainActor 上取；文件系统探查
    /// （本地日志源、缓存目录）要遍历上千个文件，必须放后台，否则按钮的
    /// ProgressView 会因为主线程被占住而根本不转。
    static func export(appState: AppState) async throws -> URL {
        AppLog.info(.app, "diagnostics export requested")
        // 最近几秒的日志可能还在缓冲里，而那几行往往正是用户刚遇到的问题。
        AppLog.shared.flushNow()

        let stateSummary = makeStateSummary(appState: appState)
        let stamp = folderStamp()
        return try await Task.detached(priority: .userInitiated) {
            let summary = Redact.scrub(stateSummary + makeFileSystemSummary())
            return try buildArchive(summary: summary, stamp: stamp)
        }.value
    }

    /// 在 Finder 中选中导出的文件。用户拖进 GitHub Issue 或聊天窗口即可。
    static func revealInFinder(_ url: URL) {
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    /// 打开日志目录本身，给想自己看日志的用户。
    /// 日志文件还没生成时直接打开目录——`activateFileViewerSelecting` 对不存在的文件是空操作。
    static func revealLogDirectory() {
        let directory = AppLog.directoryURL
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        if FileManager.default.fileExists(atPath: AppLog.currentFileURL.path) {
            NSWorkspace.shared.activateFileViewerSelecting([AppLog.currentFileURL])
        } else {
            NSWorkspace.shared.open(directory)
        }
    }

    // MARK: - 打包

    nonisolated private static let archivePrefix = "CCBar-diagnostics-"

    nonisolated private static func buildArchive(summary: String, stamp: String) throws -> URL {
        let fm = FileManager.default
        removeStaleArchives(in: fm.temporaryDirectory)

        let root = fm.temporaryDirectory
            .appendingPathComponent("\(archivePrefix)\(stamp)", isDirectory: true)
        try? fm.removeItem(at: root)
        try fm.createDirectory(at: root, withIntermediateDirectories: true)

        try Data(summary.utf8).write(
            to: root.appendingPathComponent("summary.txt", isDirectory: false),
            options: .atomic
        )
        for url in AppLog.allFileURLs where fm.fileExists(atPath: url.path) {
            try? fm.copyItem(at: url, to: root.appendingPathComponent(url.lastPathComponent))
        }

        let archive = fm.temporaryDirectory
            .appendingPathComponent("\(archivePrefix)\(stamp).zip", isDirectory: false)
        try? fm.removeItem(at: archive)

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        process.arguments = ["-c", "-k", "--sequesterRsrc", "--keepParent", root.path, archive.path]
        let errorPipe = Pipe()
        process.standardError = errorPipe
        process.standardOutput = Pipe()
        try process.run()
        let errorData = errorPipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        // 中间目录只是打包的脚手架，成功与否都清掉，不在临时目录留两份。
        try? fm.removeItem(at: root)

        guard process.terminationStatus == 0 else {
            let detail = String(data: errorData, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            throw ExportError.archiveFailed(
                detail.isEmpty ? "ditto exited with \(process.terminationStatus)" : detail
            )
        }
        return archive
    }

    /// 清掉上次导出留下的包。系统迟早会清临时目录，但用户反复导出几次就会堆好几个
    /// 同名前缀的文件，找不清哪个是刚生成的那个。
    nonisolated private static func removeStaleArchives(in directory: URL) {
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil,
            options: [.skipsSubdirectoryDescendants]
        ) else { return }
        for url in entries where url.lastPathComponent.hasPrefix(archivePrefix) {
            try? fm.removeItem(at: url)
        }
    }

    nonisolated private static func folderStamp() -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return formatter.string(from: Date())
    }

    // MARK: - 摘要（运行时状态，MainActor）

    private static func makeStateSummary(appState: AppState) -> String {
        var out = SummaryWriter()
        out.header()
        appSection(&out)
        systemSection(&out)
        settingsSection(&out)
        accountsSection(&out, appState: appState)
        quotaSection(&out, appState: appState)
        usageSection(&out, appState: appState)
        return out.text
    }

    private static func appSection(_ out: inout SummaryWriter) {
        out.section("App")
        let info = Bundle.main.infoDictionary
        out.row("version", info?["CFBundleShortVersionString"] as? String ?? "—")
        out.row("build", info?["CFBundleVersion"] as? String ?? "—")
        let path = Bundle.main.bundlePath
        out.row("installed in /Applications", String(path.hasPrefix("/Applications")))
        out.row("bundle path", Redact.path(path))
    }

    private static func systemSection(_ out: inout SummaryWriter) {
        out.section("System")
        out.row("macOS", ProcessInfo.processInfo.operatingSystemVersionString)
        out.row("hardware", sysctlString("hw.model") ?? "—")
        #if arch(arm64)
        out.row("architecture", "arm64")
        #elseif arch(x86_64)
        out.row("architecture", "x86_64")
        #else
        out.row("architecture", "unknown")
        #endif
        out.row("system locale", Locale.current.identifier)
        out.row("time zone", TimeZone.current.identifier)
        out.row("generated at", AppLog.timestamp(Date()))
    }

    private static func settingsSection(_ out: inout SummaryWriter) {
        let settings = SettingsStore.shared
        out.section("Settings")
        out.row("language", settings.appLanguage.rawValue)
        out.row("quota interval", settings.quotaInterval.rawValue)
        out.row("usage interval", settings.usageInterval.rawValue)
        out.row("menu bar window", settings.menuBarWindow.rawValue)
        out.row("floating HUD", String(settings.floatingEnabled))
        out.row("reset time display", settings.resetTimeDisplay.rawValue)
        out.row("service status dots", String(settings.showServiceStatus))
        out.row("privacy mode", String(settings.privacyMode))
        out.row("launch at login", String(settings.launchAtLogin))
        out.row("auto check updates", String(settings.autoCheckForUpdates))
        out.row("verbose logging", String(settings.verboseLogging))
        out.row("command code credential", settings.commandCodeCredentialPreference.rawValue)
        out.row("onboarding completed", String(settings.didCompleteOnboarding))
        for provider in QuotaProviderDescriptor.allProviders {
            out.row(
                "provider \(provider.app.rawValue)",
                "enabled=\(settings.isProviderEnabled(provider.app))"
                    + " menuBar=\(settings.isProviderShownInMenuBar(provider.app))"
                    + " hud=\(settings.isProviderShownInFloatingHUD(provider.app))"
            )
        }
        for app in UsageApp.allCases {
            out.row("usage stats \(app.rawValue)", String(settings.isUsageServiceVisible(app)))
        }
    }

    /// 账号标识全部走 `Redact.account`，摘要里只有哈希、套餐与过期状态，没有邮箱。
    private static func accountsSection(_ out: inout SummaryWriter, appState: AppState) {
        out.section("Accounts")
        if let c = appState.codexAccount {
            out.row("codex", "account=\(Redact.account(c.email)) id=\(Redact.account(c.accountId))"
                + " plan=\(c.planType ?? "—") expiredGuess=\(c.expiredGuess)"
                + " hasAccess=\(c.accessToken != nil) hasRefresh=\(c.refreshToken != nil)")
        } else {
            out.row("codex", "not loaded: \(Redact.message(appState.codexError))")
        }
        if let c = appState.claudeAccount {
            out.row("claude", "source=\(c.source.rawValue) account=\(Redact.account(c.email))"
                + " plan=\(c.subscriptionType ?? "—") expiresAt=\(stamp(c.expiresAt))"
                + " expiredGuess=\(c.expiredGuess) hasAccess=\(c.accessToken != nil)")
        } else {
            out.row("claude", "not loaded: \(Redact.message(appState.claudeError))")
        }
        if let c = appState.antigravityAccount {
            out.row("antigravity", "account=\(Redact.account(c.email)) plan=\(c.planType ?? "—")"
                + " expiry=\(stamp(c.expiryDate)) hasAccess=\(c.accessToken != nil)")
        } else {
            out.row("antigravity", "not loaded: \(Redact.message(appState.antigravityError))")
        }
        if let c = appState.cursorAccount {
            out.row("cursor", "account=\(Redact.account(c.email)) id=\(Redact.account(c.userID))"
                + " expiresAt=\(stamp(c.expiresAt))")
        } else {
            out.row("cursor", "not loaded: \(Redact.message(appState.cursorError))")
        }
        if let c = appState.commandCodeAccount {
            out.row("command code", "account=\(Redact.account(c.login))"
                + " source=\(c.source.displayName) plan=\(c.planType ?? "—")")
        } else {
            out.row("command code", "not loaded: \(Redact.message(appState.commandCodeError))")
        }
        out.row("imported codex accounts", String(appState.importedCodexAccounts.count))
    }

    private static func quotaSection(_ out: inout SummaryWriter, appState: AppState) {
        out.section("Quota")
        for provider in QuotaProviderDescriptor.allProviders {
            let app = provider.app
            let refresh = appState.refreshState(for: app)
            if let snapshot = appState.quotaSnapshot(for: app) {
                out.row(app.rawValue, "source=\(appState.quotaSource(for: app)?.rawValue ?? "—")"
                    + " plan=\(snapshot.planType ?? "—") fetchedAt=\(stamp(snapshot.fetchedAt))"
                    + " \(describe(snapshot))")
            } else {
                out.row(app.rawValue, "no snapshot: \(Redact.message(appState.quotaError(for: app)))")
            }
            out.row("  \(app.rawValue) refresh", "lastSuccess=\(stamp(refresh.lastSuccessAt))"
                + " lastAttempt=\(stamp(refresh.lastAttemptAt))"
                + " backoffUntil=\(stamp(refresh.backoffUntil))"
                + " inFlight=\(refresh.inFlight)"
                + " networkError=\(refresh.lastErrorIsNetwork)"
                + " lastError=\(Redact.message(refresh.lastError))")
        }
    }

    private static func usageSection(_ out: inout SummaryWriter, appState: AppState) {
        out.section("Usage")
        let service = appState.usageService
        out.row("last scan", stamp(service.lastScanAt))
        out.row("last error", Redact.message(service.lastError))
        out.row("cursor remote error", Redact.message(service.cursorRemoteUsageError))
        out.row("cursor covered ranges", String(service.cursorUsageCoveredDayRanges.count))
        out.row("cycle needs recalc", String(service.cycleUsageNeedsManualRecalculation))
        out.row("quota history events", String(appState.quotaHistory.events.count))
        out.row("quota cycle records", String(appState.quotaCycles.records.count))
    }

    private static func describe(_ snapshot: QuotaSnapshot) -> String {
        var parts: [String] = []
        if let limit = snapshot.primaryLimit {
            parts.append("primary[\(limit.kind.rawValue)]=\(describe(limit.window))")
        }
        if let limit = snapshot.secondaryLimit {
            parts.append("secondary[\(limit.kind.rawValue)]=\(describe(limit.window))")
        }
        if snapshot.isUnlimited == true { parts.append("unlimited") }
        parts += snapshot.auxiliaryLimits.map { "auxiliary[\($0.id)]=\(describe($0.window))" }
        parts += snapshot.modelLimits.map { "model[\($0.id)]=\(describe($0.window))" }
        if let window = snapshot.geminiWindow { parts.append("gemini=\(describe(window))") }
        if let window = snapshot.geminiWeekly { parts.append("geminiWeekly=\(describe(window))") }
        return parts.joined(separator: " ")
    }

    private static func describe(_ window: QuotaWindow) -> String {
        let percent = String(format: "%.1f%%", window.remainingPercent)
        return "\(percent) left (resets \(stamp(window.resetsAt)))"
    }

    // MARK: - 摘要（文件系统探查，后台）

    nonisolated private static func makeFileSystemSummary() -> String {
        var out = SummaryWriter()
        localSourcesSection(&out)
        cachesSection(&out)
        logFilesSection(&out)
        return out.text
    }

    /// 本地日志源只报存在性、文件数量级与最近修改时间。**不列文件名、不列项目名。**
    nonisolated private static func localSourcesSection(_ out: inout SummaryWriter) {
        out.section("Local usage sources")
        let home = FileManager.default.homeDirectoryForCurrentUser
        let sources: [(String, URL)] = [
            ("~/.codex/sessions", home.appendingPathComponent(".codex/sessions", isDirectory: true)),
            ("~/.codex/archived_sessions", home.appendingPathComponent(".codex/archived_sessions", isDirectory: true)),
            ("~/.claude/projects", home.appendingPathComponent(".claude/projects", isDirectory: true)),
            ("~/.pi/agent/sessions", home.appendingPathComponent(".pi/agent/sessions", isDirectory: true)),
            ("~/.local/share/opencode/opencode.db", home.appendingPathComponent(".local/share/opencode/opencode.db", isDirectory: false)),
        ]
        for (label, url) in sources {
            out.row(label, describeSource(url))
        }
    }

    nonisolated private static func cachesSection(_ out: inout SummaryWriter) {
        out.section("Caches (~/Library/Application Support/CCBar)")
        let fm = FileManager.default
        let support = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? fm.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support", isDirectory: true)
        let directory = support.appendingPathComponent("CCBar", isDirectory: true)
        guard let entries = try? fm.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.fileSizeKey, .contentModificationDateKey]
        ), !entries.isEmpty else {
            out.row("directory", "missing or empty")
            return
        }
        for url in entries.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
            let values = try? url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
            out.row(url.lastPathComponent, "\(values?.fileSize ?? 0) bytes"
                + " modified=\(stamp(values?.contentModificationDate))")
        }
    }

    nonisolated private static func logFilesSection(_ out: inout SummaryWriter) {
        out.section("Log files")
        let fm = FileManager.default
        for url in AppLog.allFileURLs {
            guard fm.fileExists(atPath: url.path) else { continue }
            let values = try? url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
            out.row(url.lastPathComponent, "\(values?.fileSize ?? 0) bytes"
                + " modified=\(stamp(values?.contentModificationDate))")
        }
    }

    /// 目录下 `.jsonl` 的数量与最新修改时间。重度用户这里有几千个文件，
    /// 所以只在后台调用；计数上限防止极端情况下把导出拖成几十秒。
    nonisolated private static func describeSource(_ url: URL) -> String {
        let fm = FileManager.default
        var isDirectory: ObjCBool = false
        guard fm.fileExists(atPath: url.path, isDirectory: &isDirectory) else { return "missing" }
        if !isDirectory.boolValue {
            let values = try? url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
            return "present \(values?.fileSize ?? 0) bytes modified=\(stamp(values?.contentModificationDate))"
        }
        let countLimit = 50_000
        var fileCount = 0
        var latest: Date?
        var truncated = false
        if let walker = fm.enumerator(
            at: url,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) {
            for case let child as URL in walker {
                guard child.pathExtension == "jsonl" else { continue }
                fileCount += 1
                if fileCount > countLimit {
                    truncated = true
                    break
                }
                if let modified = try? child.resourceValues(forKeys: [.contentModificationDateKey])
                    .contentModificationDate, modified > (latest ?? .distantPast) {
                    latest = modified
                }
            }
        }
        let count = truncated ? ">\(countLimit)" : String(fileCount)
        return "present files=\(count) newest=\(stamp(latest))"
    }

    // MARK: - 工具

    nonisolated private static func stamp(_ date: Date?) -> String {
        guard let date else { return "—" }
        return AppLog.timestamp(date)
    }

    nonisolated private static func sysctlString(_ name: String) -> String? {
        var size = 0
        guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 0 else { return nil }
        var buffer = [CChar](repeating: 0, count: size)
        guard sysctlbyname(name, &buffer, &size, nil, 0) == 0 else { return nil }
        return String(cString: buffer)
    }

    // MARK: - 摘要排版

    /// 显式 `nonisolated`：嵌套类型会继承外层的 `@MainActor` 隔离，而文件系统那一段
    /// 必须能在后台任务里用它（同 `UsageLogWatcher` 里那个盒子的理由）。
    nonisolated private struct SummaryWriter {
        private(set) var text = ""

        mutating func header() {
            text += """
                CCBar diagnostics summary

                This file is redacted: it contains no access tokens, API keys, plain-text email
                addresses, conversation content, file contents, or project names. Account
                identities appear only as one-way hashes (acct#xxxxxxxx).

                这份文件已脱敏：不含登录令牌、API key、明文邮箱、对话内容、文件内容或项目名。
                账号标识只以单向哈希（acct#xxxxxxxx）出现。

                """
        }

        mutating func section(_ title: String) {
            text += "\n## \(title)\n"
        }

        mutating func row(_ key: String, _ value: String) {
            let padded = key.count >= 30 ? key : key.padding(toLength: 30, withPad: " ", startingAt: 0)
            text += "\(padded) \(value)\n"
        }
    }
}
