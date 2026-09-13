import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var openStatisticsWindow: (() -> Void)?
    private var shouldOpenStatisticsWhenReady = false

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
