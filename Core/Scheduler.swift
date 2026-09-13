import AppKit
import CoreGraphics
import Foundation

/// 周期刷新调度。
///
/// **单一时基**：额度 / 用量 / 服务状态三件事共用一个循环，而不是各起一个
/// `Task.sleep` 循环。循环每次只睡到「最近一个到期任务」，醒来后把落在
/// `coalescingWindow` 内的任务一并执行——2 分钟与 5 分钟的任务因此会在 10 分钟处
/// 合并成一次唤醒，而不是各自独立唤醒。macOS 的能耗计分里 wakeups/sec 权重很高，
/// 三个独立循环每小时约 72 次唤醒，合并后降到约 36 次。
///
/// **系统状态感知**：系统睡眠期间停表（`Task.sleep` 走连续时钟，不停表的话唤醒瞬间
/// 会把整段睡眠期积压的周期一次性触发）；屏幕休眠或锁屏期间按
/// `powerSavingFactor` 降频——此时菜单栏和悬浮窗都不可见，高频刷新纯属浪费，
/// 尤其额度刷新是网络请求，会反复唤醒 Wi-Fi 无线电。恢复可见时立即补一次全量刷新，
/// 用户解锁看到的第一眼就是新数据。
@MainActor
final class Scheduler {
    private weak var appState: AppState?
    private var loopTask: Task<Void, Never>?
    private var observers: [(center: NotificationCenter, token: NSObjectProtocol)] = []
    private(set) var quotaInterval: TimeInterval?
    private(set) var usageInterval: TimeInterval?

    /// statuspage.io 变化很慢,固定 5 分钟一次,不跟 quotaInterval 抖。
    private let serviceStatusInterval: TimeInterval = 5 * 60

    /// 醒来后一并执行的到期容差。给足几秒，让间隔互为倍数的任务稳定合并到同一次唤醒，
    /// 不因各自起算时刻的毫秒级偏差反复错开。
    private static let coalescingWindow: TimeInterval = 5

    /// 屏幕休眠 / 锁屏期间的间隔放大倍数。
    private static let powerSavingFactor: Double = 4

    /// 屏幕关闭或已锁屏——界面不可见，按 `powerSavingFactor` 降频。
    private var isDisplayIdle = false {
        didSet {
            guard isDisplayIdle != oldValue else { return }
            AppLog.debug(.app, isDisplayIdle
                ? "display idle; polling slowed by \(Int(Self.powerSavingFactor))x"
                : "display active; polling restored and refreshing now")
            if isDisplayIdle {
                // 降频立刻生效：把已排期但还很远的任务重排到新间隔上，
                // 避免刚进入锁屏还按原频率再跑几轮。
                rescheduleAll(from: Date())
                restartLoop()
            } else {
                // 恢复可见：立即补一次全量刷新，并以此刻为新起点重排。
                fireAllNow()
            }
        }
    }

    private enum Job: CaseIterable {
        case quota
        case usage
        case serviceStatus
    }

    private var nextDue: [Job: Date] = [:]

    func start(appState: AppState, quotaInterval: TimeInterval?, usageInterval: TimeInterval?) {
        self.appState = appState
        self.quotaInterval = quotaInterval
        self.usageInterval = usageInterval
        stop()
        registerSystemObservers()
        // 开机自启常发生在锁屏状态下，此时收不到 screenIsLocked 通知，必须主动探一次，
        // 否则会一路全速跑到用户解锁。
        isDisplayIdle = Self.isScreenLocked()
        rescheduleAll(from: Date())
        restartLoop()
    }

    func stop() {
        loopTask?.cancel()
        loopTask = nil
    }

    /// 立即触发一次刷新（不打断现有周期）
    func refreshNow() {
        guard let appState else { return }
        Task { await appState.refreshQuotas(reason: .userInitiated) }
    }

    func setQuotaInterval(_ seconds: TimeInterval?) {
        guard seconds != quotaInterval else { return }
        quotaInterval = seconds
        reschedule(.quota, from: Date())
        restartLoop()
    }

    func setUsageInterval(_ seconds: TimeInterval?) {
        guard seconds != usageInterval else { return }
        usageInterval = seconds
        reschedule(.usage, from: Date())
        restartLoop()
    }

    // MARK: - 系统状态

    private func registerSystemObservers() {
        guard observers.isEmpty else { return }
        let workspace = NSWorkspace.shared.notificationCenter
        let distributed = DistributedNotificationCenter.default()

        // 系统睡眠：停表。唤醒后重排时基并立即补一次刷新，
        // 不让整段睡眠期积压的周期在唤醒瞬间一次性打出去。
        observe(workspace, NSWorkspace.willSleepNotification, .stopClock)
        observe(workspace, NSWorkspace.didWakeNotification, .wake)
        // 屏幕休眠 / 唤醒。
        observe(workspace, NSWorkspace.screensDidSleepNotification, .displayIdle(true))
        observe(workspace, NSWorkspace.screensDidWakeNotification, .displayIdle(false))
        // 锁屏 / 解锁（分布式通知，无公开常量）。
        observe(distributed, Notification.Name("com.apple.screenIsLocked"), .displayIdle(true))
        observe(distributed, Notification.Name("com.apple.screenIsUnlocked"), .displayIdle(false))
    }

    /// 通知要触发的动作。用值而不是闭包传递，避免把非 Sendable 的闭包
    /// 捕获进 `addObserver` 的 `@Sendable` block。
    private enum SystemEvent: Sendable {
        case stopClock
        case wake
        case displayIdle(Bool)
    }

    private func observe(_ center: NotificationCenter, _ name: Notification.Name, _ event: SystemEvent) {
        let token = center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                switch event {
                case .stopClock:
                    self.stop()
                case .wake:
                    self.fireAllNow()
                case .displayIdle(let idle):
                    self.isDisplayIdle = idle
                }
            }
        }
        observers.append((center, token))
    }

    /// 当前会话是否处于锁屏 / 未占用控制台状态。仅用于启动时取初始值，
    /// 之后由通知维护。字典键在未锁定时不存在，缺失即视为未锁定。
    private static func isScreenLocked() -> Bool {
        guard let info = CGSessionCopyCurrentDictionary() as? [String: Any] else { return false }
        if let locked = info["CGSSessionScreenIsLocked"] as? Bool { return locked }
        if let onConsole = info[kCGSessionOnConsoleKey as String] as? Bool { return !onConsole }
        return false
    }

    // MARK: - 排期

    private func baseInterval(for job: Job) -> TimeInterval? {
        switch job {
        case .quota: return quotaInterval
        case .usage: return usageInterval
        case .serviceStatus: return serviceStatusInterval
        }
    }

    private func effectiveInterval(for job: Job) -> TimeInterval? {
        guard let base = baseInterval(for: job), base > 0 else { return nil }
        return isDisplayIdle ? base * Self.powerSavingFactor : base
    }

    private func reschedule(_ job: Job, from now: Date) {
        guard let interval = effectiveInterval(for: job) else {
            nextDue[job] = nil
            return
        }
        nextDue[job] = now.addingTimeInterval(interval)
    }

    private func rescheduleAll(from now: Date) {
        for job in Job.allCases { reschedule(job, from: now) }
    }

    /// 立即跑一遍全部任务并以此刻为新起点重排。用于系统唤醒 / 恢复可见。
    private func fireAllNow() {
        let now = Date()
        rescheduleAll(from: now)
        restartLoop()
        let jobs = Job.allCases.filter { effectiveInterval(for: $0) != nil }
        guard !jobs.isEmpty else { return }
        Task { [weak self] in await self?.run(jobs) }
    }

    private func restartLoop() {
        loopTask?.cancel()
        guard !nextDue.isEmpty else {
            loopTask = nil
            return
        }
        loopTask = Task { [weak self] in
            await self?.loop()
        }
    }

    private func loop() async {
        while !Task.isCancelled {
            guard let due = nextDue.values.min() else { return }
            let delay = due.timeIntervalSinceNow
            if delay > 0 {
                do {
                    try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                } catch {
                    return
                }
            }
            guard !Task.isCancelled else { return }

            let now = Date()
            let deadline = now.addingTimeInterval(Self.coalescingWindow)
            let dueJobs = Job.allCases.filter { job in
                guard let at = nextDue[job] else { return false }
                return at <= deadline
            }
            guard !dueJobs.isEmpty else { continue }
            // 先排下一轮再执行：任务本身耗时不应叠加进周期，也避免异常路径漏排。
            for job in dueJobs { reschedule(job, from: now) }
            await run(dueJobs)
        }
    }

    private func run(_ jobs: [Job]) async {
        guard let appState else { return }
        // 顺序执行：三者都会碰 @MainActor 状态，并发只会互相排队，还会让唤醒期变长。
        for job in jobs {
            guard !Task.isCancelled else { return }
            switch job {
            case .quota:
                await appState.refreshQuotas(reason: .periodic)
            case .usage:
                await appState.usageService.scanPeriodically()
            case .serviceStatus:
                await appState.refreshServiceStatus()
            }
        }
    }
}
