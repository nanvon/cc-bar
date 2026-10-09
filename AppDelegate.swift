import AppKit
import UserNotifications

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var openStatisticsWindow: (() -> Void)?
    private var shouldOpenStatisticsWhenReady = false
    private var terminationHandler: (@MainActor () async throws -> Void)?
    private var terminationFailureHandler: (@MainActor (Error) -> Bool)?
    private var terminationTask: Task<Void, Never>?
    private var quotaNotificationDelegate: QuotaNotificationDelegate?

    func applicationWillFinishLaunching(_ notification: Notification) {
        guard !AppRuntime.isRunningUnitTests else { return }
        let delegate = QuotaNotificationDelegate { [weak self] in self?.requestOpenStatisticsWindow() }
        quotaNotificationDelegate = delegate
        UNUserNotificationCenter.current().delegate = delegate
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        // 冷启动（含开机自启、Dock/应用程序/Launchpad/Raycast 手动启动）一律静默，
        // 只驻留菜单栏；主窗口只在用户点 Dock 图标触发 reopen 时才打开。
        let info = Bundle.main.infoDictionary
        AppLog.info(.app, """
            launched version=\(info?["CFBundleShortVersionString"] as? String ?? "—") \
            build=\(info?["CFBundleVersion"] as? String ?? "—") \
            macOS=\(ProcessInfo.processInfo.operatingSystemVersionString)
            """)
    }

    /// 退出前把缓冲里剩下的日志写完——崩溃前最后那几行往往正是要查的东西。
    func applicationWillTerminate(_ notification: Notification) {
        AppLog.info(.app, "terminating")
        AppLog.shared.flushNow()
    }

    /// 普通退出和更新重启都等业务数据保存成功后再退出。
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let terminationHandler else { return .terminateNow }
        guard terminationTask == nil else { return .terminateLater }
        terminationTask = Task {
            do {
                try await terminationHandler()
                sender.reply(toApplicationShouldTerminate: true)
            } catch {
                AppLog.error(.persistence, "termination cancelled: \(Redact.error(error))")
                sender.reply(toApplicationShouldTerminate: false)
                terminationTask = nil
                if terminationFailureHandler?(error) == true { return }
                let alert = NSAlert()
                alert.messageText = tr("CCBar could not quit", "CCBar 未能退出")
                alert.informativeText = error.localizedDescription
                alert.alertStyle = .warning
                alert.addButton(withTitle: tr("OK", "好"))
                NSApp.activate(ignoringOtherApps: true)
                alert.runModal()
            }
        }
        return .terminateLater
    }

    func installTerminationHandler(_ handler: @escaping @MainActor () async throws -> Void) {
        terminationHandler = handler
    }

    func installTerminationFailureHandler(_ handler: @escaping @MainActor (Error) -> Bool) {
        terminationFailureHandler = handler
    }

    func applicationShouldHandleReopen(
        _ sender: NSApplication,
        hasVisibleWindows flag: Bool
    ) -> Bool {
        requestOpenStatisticsWindow()
        return false
    }

    func installOpenStatisticsHandler(_ handler: @escaping () -> Void) {
        openStatisticsWindow = handler
        guard shouldOpenStatisticsWhenReady else { return }
        shouldOpenStatisticsWhenReady = false
        handler()
    }

    private func requestOpenStatisticsWindow() {
        guard let openStatisticsWindow else {
            shouldOpenStatisticsWhenReady = true
            return
        }
        openStatisticsWindow()
    }
}
