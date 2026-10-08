import AppKit
import Foundation
import Observation
import Sparkle
import SwiftUI

enum AppUpdatePhase: Equatable {
    case idle, checking, available, downloading, preparing, installing, upToDate, failed
}

/// 一个进程只有一个更新器。下载与安装由 Sparkle 处理，窗口关闭不结束下载。
@Observable
@MainActor
final class AppUpdater: NSObject, SPUUserDriver, SPUUpdaterDelegate, NSWindowDelegate {
    static let shared = AppUpdater()

    private(set) var phase: AppUpdatePhase = .idle
    private(set) var availableVersion: String?
    private(set) var publishedAt: Date?
    private(set) var minimumSystemVersion: String?
    private(set) var releaseNotes = ""
    private(set) var isLoadingReleaseNotes = false
    private(set) var releaseNotesError: String?
    private(set) var errorMessage: String?
    private(set) var downloadedBytes: UInt64 = 0
    private(set) var expectedBytes: UInt64 = 0
    private(set) var extractionProgress: Double = 0
    private(set) var lastCheckedAt: Date?
    private(set) var automaticChecks = SettingsStore.shared.autoCheckForUpdates
    private(set) var informationOnly = false

    @ObservationIgnored private var updater: SPUUpdater?
    @ObservationIgnored private var window: NSWindow?
    @ObservationIgnored private var item: SUAppcastItem?
    @ObservationIgnored private var updateReply: ((SPUUserUpdateChoice) -> Void)?
    @ObservationIgnored private var cancellation: (() -> Void)?
    @ObservationIgnored private var retryTermination: (() -> Void)?
    @ObservationIgnored private var installWasRequested = false
    @ObservationIgnored private var didStart = false
    @ObservationIgnored private var configurationError: String?
    @ObservationIgnored private var checkObservation: NSKeyValueObservation?
    @ObservationIgnored private var isWaitingToCheck = false
    @ObservationIgnored private let defaults = UserDefaults.standard
    private static let pendingVersionKey = "update.pendingVersion"
    private static let pendingBuildKey = "update.pendingBuild"

    var currentVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "—"
    }

    var hasUpdate: Bool { availableVersion != nil }
    var isWorking: Bool { [.checking, .downloading, .preparing, .installing].contains(phase) }
    var canInstall: Bool { phase == .available }
    var canSkipVersion: Bool { phase == .available && updateReply != nil }
    var canCancel: Bool { cancellation != nil }
    var canRetryInstallation: Bool { phase == .failed && retryTermination != nil }
    var downloadProgress: Double? {
        guard expectedBytes > 0 else { return nil }
        return min(1, Double(downloadedBytes) / Double(expectedBytes))
    }

    var statusText: String? {
        switch phase {
        case .checking: return tr("Checking for updates…", "正在检查更新…")
        case .downloading: return tr("Downloading update…", "正在下载更新…")
        case .preparing: return tr("Preparing update…", "正在准备更新…")
        case .installing: return tr("Saving and restarting…", "正在保存并重新启动…")
        case .failed: return errorMessage
        case .upToDate: return tr("You’re up to date", "已是最新版本")
        case .available, .idle:
            if let availableVersion { return tr("Version \(availableVersion) is available", "发现新版本 \(availableVersion)") }
            return nil
        }
    }

    func start() {
        guard !didStart, !AppRuntime.isRunningUnitTests else { return }
        didStart = true
        confirmInstalledUpdate()
        // 只迁移旧偏好一次；后续检查设置直接由 Sparkle 的 UserDefaults 管理。
        if defaults.object(forKey: "SUEnableAutomaticChecks") == nil {
            defaults.set(automaticChecks, forKey: "SUEnableAutomaticChecks")
        }
        guard let publicKey = Bundle.main.object(forInfoDictionaryKey: "SUPublicEDKey") as? String,
              Data(base64Encoded: publicKey)?.count == 32 else {
            configurationError = tr(
                "In-app installation is unavailable in this build. Download CCBar from the release page.",
                "此构建尚未启用应用内安装，请从发布页手动下载 CCBar。"
            )
            return
        }
        let updater = SPUUpdater(hostBundle: .main, applicationBundle: .main, userDriver: self, delegate: self)
        do {
            try updater.start()
            self.updater = updater
            checkObservation = updater.observe(\.canCheckForUpdates, options: [.new]) { [weak self] _, change in
                guard change.newValue == true else { return }
                Task { @MainActor [weak self] in self?.performPendingManualCheck() }
            }
            automaticChecks = updater.automaticallyChecksForUpdates
            lastCheckedAt = updater.lastUpdateCheckDate
            if automaticChecks { updater.checkForUpdatesInBackground() }
        } catch {
            configurationError = error.localizedDescription
            AppLog.error(.app, "[update] updater configuration failed: \(error.localizedDescription)")
        }
    }

    func setAutomaticChecks(_ enabled: Bool) {
        automaticChecks = enabled
        if let updater {
            updater.automaticallyChecksForUpdates = enabled
        } else {
            defaults.set(enabled, forKey: "SUEnableAutomaticChecks")
        }
    }

    /// Popover 仅查看已有更新或任务，不额外发起检查。
    func showUpdateWindow() {
        showWindow()
    }

    /// 手动检查或重新打开当前更新，始终复用同一窗口与下载任务。
    func checkForUpdates() {
        start()
        showWindow()
        if isWorking || updateReply != nil || retryTermination != nil { return }
        if let configurationError {
            errorMessage = configurationError
            phase = .failed
            return
        }
        guard let updater else { return }
        guard updater.canCheckForUpdates else {
            // Sparkle 可能在探测安装器或后台读取清单，待它恢复可检查时再执行。
            isWaitingToCheck = true
            phase = .checking
            return
        }
        errorMessage = nil
        phase = .checking
        updater.checkForUpdates()
    }

    private func performPendingManualCheck() {
        guard isWaitingToCheck, let updater, updater.canCheckForUpdates else { return }
        isWaitingToCheck = false
        if updateReply != nil { return }
        phase = .checking
        updater.checkForUpdates()
    }

    func installUpdate() {
        guard canInstall else { return }
        guard let reply = updateReply else {
            // 取消后的旧回调不能复用，重新检查并重新授权新的会话。
            checkForUpdates()
            return
        }
        updateReply = nil
        if informationOnly {
            openReleasePage()
            reply(.dismiss)
            return
        }
        installWasRequested = true
        phase = .downloading
        reply(.install)
    }

    func skipVersion() {
        guard let reply = updateReply else { return }
        updateReply = nil
        availableVersion = nil
        item = nil
        releaseNotes = ""
        phase = .idle
        reply(.skip)
        window?.close()
    }

    func cancelDownloadOrCheck() {
        if isWaitingToCheck {
            isWaitingToCheck = false
            phase = hasUpdate ? .available : .idle
            return
        }
        guard let cancel = cancellation else { return }
        cancellation = nil
        installWasRequested = false
        defaults.removeObject(forKey: Self.pendingVersionKey)
        defaults.removeObject(forKey: Self.pendingBuildKey)
        cancel()
        phase = hasUpdate ? .available : .idle
    }

    func retry() {
        if let retryTermination {
            errorMessage = nil
            phase = .installing
            retryTermination()
        } else {
            checkForUpdates()
        }
    }

    func terminationPreparationFailed(_ error: Error) -> Bool {
        guard retryTermination != nil else { return false }
        phase = .failed
        errorMessage = tr("Installation paused. \(error.localizedDescription)", "安装已暂停。\(error.localizedDescription)")
        showWindow()
        return true
    }

    func openReleasePage() {
        let url = item?.infoURL ?? UpdateChecker.releasePageURL
        guard url.scheme == "https" else { return }
        NSWorkspace.shared.open(url)
    }

    func closeWindow() {
        window?.close()
    }

    private func showWindow() {
        if window == nil {
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 560, height: 540),
                styleMask: [.titled, .closable, .miniaturizable, .resizable],
                backing: .buffered, defer: false
            )
            window.title = tr("CCBar Update", "CCBar 更新")
            window.contentView = NSHostingView(rootView: AppUpdateWindow(updater: self))
            window.minSize = NSSize(width: 500, height: 420)
            window.isReleasedWhenClosed = false
            window.delegate = self
            window.center()
            self.window = window
        }
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }

    func windowWillClose(_ notification: Notification) {
        if phase == .available {
            let reply = updateReply
            updateReply = nil
            reply?(.dismiss)
        } else if phase == .checking {
            cancelDownloadOrCheck()
        }
    }

    private func confirmInstalledUpdate() {
        guard let expected = defaults.string(forKey: Self.pendingVersionKey),
              let build = defaults.string(forKey: Self.pendingBuildKey) else { return }
        if Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String == build {
            defaults.removeObject(forKey: Self.pendingVersionKey)
            defaults.removeObject(forKey: Self.pendingBuildKey)
            AppLog.info(.app, "[update] installed version=\(expected)")
        }
    }

    // MARK: SPUUserDriver — 所有回调由 Sparkle 在主线程调用。

    func show(_ request: SPUUpdatePermissionRequest, reply: @escaping (SUUpdatePermissionResponse) -> Void) {
        // Info.plist 明确配置自动检查，不弹第二套偏好询问，也不发送系统画像。
        reply(SUUpdatePermissionResponse(automaticUpdateChecks: automaticChecks, sendSystemProfile: false))
    }

    func showUserInitiatedUpdateCheck(cancellation: @escaping () -> Void) {
        self.cancellation = cancellation
        errorMessage = nil
        phase = .checking
        showWindow()
    }

    func showUpdateFound(with appcastItem: SUAppcastItem, state: SPUUserUpdateState, reply: @escaping (SPUUserUpdateChoice) -> Void) {
        isWaitingToCheck = false
        cancellation = nil
        installWasRequested = false
        retryTermination = nil
        item = appcastItem
        availableVersion = appcastItem.displayVersionString
        publishedAt = appcastItem.date
        minimumSystemVersion = appcastItem.minimumSystemVersion
        informationOnly = appcastItem.isInformationOnlyUpdate
        expectedBytes = appcastItem.contentLength
        downloadedBytes = 0
        extractionProgress = 0
        errorMessage = nil
        releaseNotesError = nil
        releaseNotes = appcastItem.itemDescription ?? ""
        isLoadingReleaseNotes = appcastItem.releaseNotesURL != nil
        updateReply = reply
        phase = .available
        lastCheckedAt = updater?.lastUpdateCheckDate ?? .now
        // 后台发现只显示入口状态；主动检查才显示窗口。
        if state.userInitiated { showWindow() }
    }

    func showUpdateReleaseNotes(with downloadData: SPUDownloadData) {
        isLoadingReleaseNotes = false
        guard let notes = String(data: downloadData.data, encoding: .utf8) else {
            releaseNotesError = tr("Release notes could not be displayed.", "更新内容无法显示。")
            return
        }
        releaseNotes = UpdateReleaseNotes.changes(in: notes, since: currentVersion)
    }

    func showUpdateReleaseNotesFailedToDownloadWithError(_ error: Error) {
        isLoadingReleaseNotes = false
        releaseNotesError = tr("Release notes could not be loaded. View them on the release page.", "更新内容加载失败，可在发布页查看。")
    }

    func showUpdateNotFoundWithError(_ error: Error, acknowledgement: @escaping () -> Void) {
        cancellation = nil
        let nsError = error as NSError
        let reason = (nsError.userInfo[SPUNoUpdateFoundReasonKey] as? NSNumber)?.intValue
        // Sparkle 的 reason 1/2 是最新或比公开版本更新，3～5 是系统/架构不兼容。
        phase = (reason == 1 || reason == 2) ? .upToDate : .failed
        availableVersion = nil
        item = nil
        releaseNotes = ""
        isLoadingReleaseNotes = false
        // Sparkle 的错误同时涵盖“系统不兼容”，保留它提供的说明，避免误报最新。
        errorMessage = phase == .failed ? (nsError.localizedRecoverySuggestion ?? nsError.localizedDescription) : nil
        showWindow()
        acknowledgement()
    }

    func showUpdaterError(_ error: Error, acknowledgement: @escaping () -> Void) {
        phase = .failed
        errorMessage = error.localizedDescription
        isLoadingReleaseNotes = false
        installWasRequested = false
        showWindow()
        acknowledgement()
    }

    func showDownloadInitiated(cancellation: @escaping () -> Void) {
        self.cancellation = cancellation
        downloadedBytes = 0
        phase = .downloading
    }

    func showDownloadDidReceiveExpectedContentLength(_ expectedContentLength: UInt64) { expectedBytes = expectedContentLength }
    func showDownloadDidReceiveData(ofLength length: UInt64) { downloadedBytes &+= length }
    func showDownloadDidStartExtractingUpdate() {
        cancellation = nil
        phase = .preparing
    }
    func showExtractionReceivedProgress(_ progress: Double) { extractionProgress = min(1, max(0, progress)) }

    func showReady(toInstallAndRelaunch reply: @escaping (SPUUserUpdateChoice) -> Void) {
        guard installWasRequested else {
            // 恢复的旧更新也必须获得用户本次明确授权。
            updateReply = reply
            phase = .available
            return
        }
        phase = .installing
        reply(.install)
    }

    func showInstallingUpdate(withApplicationTerminated applicationTerminated: Bool, retryTerminatingApplication: @escaping () -> Void) {
        phase = .installing
        cancellation = nil
        retryTermination = applicationTerminated ? nil : retryTerminatingApplication
    }

    func showUpdateInstalledAndRelaunched(_ relaunched: Bool, acknowledgement: @escaping () -> Void) {
        phase = .idle
        acknowledgement()
    }

    func dismissUpdateInstallation() {
        updateReply = nil
        cancellation = nil
        retryTermination = nil
        installWasRequested = false
        if [.checking, .downloading, .preparing, .installing].contains(phase) {
            phase = hasUpdate ? .available : .idle
        }
    }

    func showUpdateInFocus() { showWindow() }

    // MARK: SPUUpdaterDelegate

    func updater(_ updater: SPUUpdater, didFindValidUpdate item: SUAppcastItem) {
        lastCheckedAt = updater.lastUpdateCheckDate ?? .now
    }

    func updaterDidNotFindUpdate(_ updater: SPUUpdater, error: Error) {
        isWaitingToCheck = false
        lastCheckedAt = updater.lastUpdateCheckDate ?? .now
        if phase == .checking {
            let nsError = error as NSError
            let reason = (nsError.userInfo[SPUNoUpdateFoundReasonKey] as? NSNumber)?.intValue
            phase = (reason == 1 || reason == 2) ? .upToDate : .failed
            errorMessage = phase == .failed ? (nsError.localizedRecoverySuggestion ?? nsError.localizedDescription) : nil
        }
    }

    func updater(_ updater: SPUUpdater, didFinishUpdateCycleFor updateCheck: SPUUpdateCheck, error: Error?) {
        lastCheckedAt = updater.lastUpdateCheckDate
        if phase == .checking, let error {
            isWaitingToCheck = false
            errorMessage = error.localizedDescription
            phase = .failed
        }
    }

    func updater(_ updater: SPUUpdater, willInstallUpdate item: SUAppcastItem) {
        defaults.set(item.displayVersionString, forKey: Self.pendingVersionKey)
        defaults.set(item.versionString, forKey: Self.pendingBuildKey)
    }
}

/// 历史 Markdown 只展示已安装版本之后的变化；没有版本分组的单版说明原样保留。
nonisolated enum UpdateReleaseNotes {
    static func changes(in markdown: String, since version: String) -> String {
        let lines = markdown.components(separatedBy: .newlines)
        var result: [String] = []
        var hasVersions = false
        var include = true
        for line in lines {
            if line.range(of: "^## v?[0-9]+\\.[0-9]+\\.[0-9]+(?:\\s|$)", options: .regularExpression) != nil,
               let tag = line.dropFirst(3).split(separator: " ").first {
                hasVersions = true
                include = UpdateChecker.isNewer(tag: String(tag), than: version)
            }
            if include { result.append(line) }
        }
        return hasVersions ? result.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines) : markdown
    }
}
