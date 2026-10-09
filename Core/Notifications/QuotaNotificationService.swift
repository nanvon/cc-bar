import Foundation
import Observation

/// 一个持有的消费任务串行处理全部成功事件；await 时到达的观察只进入队列。
@Observable
@MainActor
final class QuotaNotificationService {
    private(set) var permissionState: QuotaNotificationPermission?
    private(set) var authorizationFailed = false
    private(set) var permissionReadFailed = false
    private(set) var storagePaused = false
    private(set) var isRequestingAuthorization = false
    private(set) var isRebuilding = false
    private(set) var recordCount = 0
    private(set) var fileSize = 0
    private(set) var lastError: String?

    @ObservationIgnored private let client: any QuotaNotificationClient
    @ObservationIgnored private let store: QuotaAlertStore
    @ObservationIgnored private let preferences: () -> QuotaAlertPreferences
    @ObservationIgnored private let context: (QuotaAlertObservation) -> QuotaAlertDisplayContext?
    @ObservationIgnored private let activeIdentities: () -> [QuotaAlertIdentity]
    @ObservationIgnored private let initialized: () -> Bool
    @ObservationIgnored private let markInitialized: () -> Void
    @ObservationIgnored private let now: () -> Date
    @ObservationIgnored private let loggingEnabled: Bool
    @ObservationIgnored private let translate: @MainActor (String, String) -> String
    @ObservationIgnored private let displayAccount: @MainActor (QuotaAlertDisplayContext) -> String
    @ObservationIgnored private let resetHint: @MainActor (Date, Date) -> String
    @ObservationIgnored private var payload: QuotaAlertPayload?
    @ObservationIgnored private var queue: [QuotaAlertObservation] = []
    @ObservationIgnored private var worker: Task<Void, Never>?
    @ObservationIgnored private var cleanup: Task<Void, Never>?
    @ObservationIgnored private var processed: [UUID] = []
    @ObservationIgnored private var stopping = false
    @ObservationIgnored private var fatalStorageError = false
    @ObservationIgnored private var nextStorageRetry: Date?
    /// 在途提交对应的账号键；提交期间若有覆盖它的清理请求，完成后补清理一次。
    @ObservationIgnored private var inFlightKeys: Set<String> = []
    @ObservationIgnored private var inFlightCleared = false
    @ObservationIgnored private var permissionVersion: UInt64 = 0
    @ObservationIgnored private var lastEnabled: Bool?

    init(
        client: any QuotaNotificationClient, store: QuotaAlertStore,
        preferences: @escaping () -> QuotaAlertPreferences,
        context: @escaping (QuotaAlertObservation) -> QuotaAlertDisplayContext?,
        activeIdentities: @escaping () -> [QuotaAlertIdentity],
        initialized: @escaping () -> Bool, markInitialized: @escaping () -> Void,
        now: @escaping () -> Date = Date.init, loggingEnabled: Bool = true,
        translate: @escaping @MainActor (String, String) -> String = tr,
        displayAccount: @escaping @MainActor (QuotaAlertDisplayContext) -> String = {
            PrivacyDisplay.isEnabled ? PrivacyDisplay.account($0.privacyKey) : $0.name
        },
        resetHint: @escaping @MainActor (Date, Date) -> String = { formatResetHint($0, now: $1) }
    ) {
        self.client = client
        self.store = store
        self.preferences = preferences
        self.context = context
        self.activeIdentities = activeIdentities
        self.initialized = initialized
        self.markInitialized = markInitialized
        self.now = now
        self.loggingEnabled = loggingEnabled
        self.translate = translate
        self.displayAccount = displayAccount
        self.resetHint = resetHint
    }

    private func log(_ level: AppLogLevel, _ category: AppLogCategory, _ message: @autoclosure () -> String) {
        guard loggingEnabled else { return }
        AppLog.log(level, category, message())
    }

    var statusText: String? {
        guard preferences().enabled else { return nil }
        if storagePaused { return translate("Could not save alert history. Alerts are paused.", "无法保存提醒记录，提醒已暂停") }
        if permissionReadFailed { return translate("Could not read notification settings. Try again.", "无法读取通知设置，请重试") }
        if authorizationFailed { return translate("Could not request notification permission. Try again.", "无法申请通知权限，请重试") }
        if let permissionState, !permissionState.canSubmit {
            return translate("Notifications are not allowed. Enable them in System Settings.", "系统通知未允许，请在系统设置中开启")
        }
        return nil
    }

    @discardableResult
    func refreshPermission() async -> Bool {
        guard !stopping, !AppRuntime.isRunningUnitTests || !(client is SystemNotificationClient) else { return false }
        permissionVersion &+= 1
        let version = permissionVersion
        do {
            let permission = try await client.permission()
            guard version == permissionVersion else { return false }
            permissionState = permission
            permissionReadFailed = false
            return true
        } catch {
            guard version == permissionVersion else { return false }
            permissionState = nil
            permissionReadFailed = true
            lastError = Redact.error(error)
            log(.error, .app, "quota alert permission read failed: \(Redact.error(error))")
            return false
        }
    }

    /// 仅主动开启提醒或开启声音时调用；拒绝后不通过开关反复申请。
    func requestPermissionIfNeeded() async {
        guard preferences().enabled, !isRequestingAuthorization, !stopping else { return }
        isRequestingAuthorization = true
        defer { isRequestingAuthorization = false }
        guard await refreshPermission() else { return }
        guard preferences().enabled, !stopping, let permissionState else { return }
        if permissionState.authorization == .notDetermined
            || (permissionState.authorization == .allowed && preferences().sound && !permissionState.sound) {
            do {
                try await client.requestAuthorization(sound: preferences().sound)
                authorizationFailed = false
            } catch {
                authorizationFailed = true
                lastError = Redact.error(error)
                log(.error, .app, "quota alert authorization failed: \(Redact.error(error))")
            }
            await refreshPermission()
        }
    }

    func settingsChanged(clearNotifications: Bool = false) {
        if !preferences().enabled { queue.removeAll() }
        if clearNotifications || !preferences().enabled { removeNotifications() }
        if lastEnabled != preferences().enabled {
            lastEnabled = preferences().enabled
            log(.info, .quota, "quota alerts enabled=\(preferences().enabled)")
        }
    }

    func removeNotifications(accountKey: String? = nil) {
        if accountKey.map(inFlightKeys.contains) ?? true { inFlightCleared = true }
        let previous = cleanup
        let client = client
        cleanup = Task {
            await previous?.value
            await client.removeNotifications(accountKey: accountKey)
        }
    }

    func enqueue(_ observation: QuotaAlertObservation) {
        guard !stopping, !isRebuilding, preferences().enabled else { return }
        queue.append(observation)
        guard worker == nil else { return }
        worker = Task { [weak self] in
            guard let self else { return }
            defer { self.worker = nil }
            while !self.queue.isEmpty && !self.stopping {
                let observation = self.queue.removeFirst()
                await self.consume(observation)
            }
        }
    }

    private func isCurrent(_ observation: QuotaAlertObservation) -> Bool {
        let age = now().timeIntervalSince(observation.observedAt)
        return !stopping && preferences().enabled && age >= 0 && age <= QuotaAlertPolicy.freshnessInterval
            && context(observation) != nil
    }

    private func loadIfNeeded() async -> Bool {
        if fatalStorageError { return false }
        if storagePaused, let retry = nextStorageRetry, now() < retry { return false }
        do {
            if payload == nil {
                payload = try await store.load(initialized: initialized())
                markInitialized()
                recordCount = payload?.accounts.values.reduce(0) { $0 + $1.windows.count } ?? 0
                fileSize = await store.fileSize()
            } else if storagePaused, let payload {
                try await store.save(payload)
            }
            storagePaused = false
            nextStorageRetry = nil
            return true
        } catch {
            pauseStorage(error, fatal: error is QuotaAlertStore.StoreError || error is DecodingError)
            return false
        }
    }

    private func save() async -> Bool {
        guard let payload else { return false }
        do {
            try await store.save(payload)
            recordCount = payload.accounts.values.reduce(0) { $0 + $1.windows.count }
            fileSize = await store.fileSize()
            storagePaused = false
            return true
        } catch {
            pauseStorage(error, fatal: error is QuotaAlertStore.StoreError)
            return false
        }
    }

    private func pauseStorage(_ error: Error, fatal: Bool) {
        if !storagePaused { log(.error, .persistence, "quota alerts paused: \(Redact.error(error))") }
        lastError = Redact.error(error)
        storagePaused = true
        fatalStorageError = fatal
        nextStorageRetry = now().addingTimeInterval(QuotaAlertPolicy.retryInterval)
    }

    private func consume(_ observation: QuotaAlertObservation) async {
        guard isCurrent(observation), observation.raw.app == observation.identity.app, observation.raw.isUnlimited != true,
              !processed.contains(observation.id), await loadIfNeeded(), isCurrent(observation),
              var next = payload else { return }
        processed.append(observation.id)
        if processed.count > 512 { processed.removeFirst(processed.count - 512) }
        let active = activeIdentities()
        guard let identity = QuotaAlertPolicy.resolve(observation.identity, active: active, payload: &next) else {
            log(.debug, .quota, "quota alert skipped: ambiguous identity")
            return
        }
        let prefs = preferences()
        var account = next.accounts[identity.key] ?? QuotaAlertAccountState(identity: identity)
        let baselineKey = QuotaAlertIdentity.digest([observation.entry])
        var candidates: [QuotaLimit] = []
        for limit in QuotaAlertPolicy.limits(in: observation.raw, preferences: prefs) {
            let key = QuotaAlertPolicy.windowKey(limit, app: observation.raw.app)
            let baselineWindows = next.baselineEntries[baselineKey] ?? []
            let rebuildingAll = baselineWindows.contains("*")
            let baseline = rebuildingAll ? !baselineWindows.contains(key) : baselineWindows.contains(key)
            guard let result = QuotaAlertPolicy.evaluate(
                previous: account.windows[key], window: limit.window, kind: limit.kind,
                threshold: prefs.threshold, observationID: observation.id, now: observation.observedAt,
                baseline: baseline, allowBillingCycle: observation.raw.app == .cursor || limit.id == "command-code-monthly"
            ) else { continue }
            account.windows[key] = result.record
            if rebuildingAll { next.baselineEntries[baselineKey]?.insert(key) }
            else { next.baselineEntries[baselineKey]?.remove(key) }
            if result.shouldAlert { candidates.append(limit) }
        }
        if next.baselineEntries[baselineKey]?.isEmpty == true { next.baselineEntries.removeValue(forKey: baselineKey) }
        if !account.windows.isEmpty { next.accounts[identity.key] = account }
        // 90 天未出现且已不属于任何入口的记录，随已有状态变化惰性清理。
        let activeAccounts = Set(active.map(\.accountDigest))
        next.accounts = next.accounts.filter { _, state in
            activeAccounts.contains(state.identity.accountDigest)
                || state.windows.values.contains { now().timeIntervalSince($0.lastSeenAt) < 90 * 24 * 60 * 60 }
        }
        if next != payload {
            payload = next
            guard await save() else { return }
        }
        guard !candidates.isEmpty, isCurrent(observation) else { return }
        await cleanup?.value
        guard isCurrent(observation) else { return }
        guard await refreshPermission(), isCurrent(observation), permissionState?.canSubmit == true,
              preferences() == prefs else { return }
        // 同次低额度窗口作为一个事务提交，重试复用原 request ID。
        let requestID = candidates.compactMap { account.windows[QuotaAlertPolicy.windowKey($0, app: observation.raw.app)]?.retryID }.first ?? UUID()
        let submission = QuotaAlertSubmission(id: requestID, status: .prepared, submittedAt: now())
        for limit in candidates {
            let key = QuotaAlertPolicy.windowKey(limit, app: observation.raw.app)
            account.windows[key]?.submission = submission
            account.windows[key]?.alertedThreshold = prefs.threshold
            account.windows[key]?.retryID = nil
            account.windows[key]?.retryAfter = nil
        }
        payload?.accounts[identity.key] = account
        guard await save() else { return } // 保存结果不确定也保留内存 prepared，优先少打扰。
        let authorized = isCurrent(observation) ? await refreshPermission() : false
        guard authorized, isCurrent(observation), permissionState?.canSubmit == true, preferences() == prefs,
              let displayContext = context(observation) else {
            for limit in candidates {
                let key = QuotaAlertPolicy.windowKey(limit, app: observation.raw.app)
                account.windows[key]?.submission = nil
            }
            payload?.accounts[identity.key] = account
            _ = await save()
            return
        }
        let message = makeMessage(observation, limits: candidates, context: displayContext,
                                  identity: identity, requestID: requestID)
        inFlightKeys = Set([identity.key, message.entryKey].compactMap { $0 })
        inFlightCleared = false
        defer { inFlightKeys = [] }
        do {
            try await client.submit(message)
            for limit in candidates {
                let key = QuotaAlertPolicy.windowKey(limit, app: observation.raw.app)
                account.windows[key]?.submission?.status = .accepted
            }
            payload?.accounts[identity.key] = account
            _ = await save()
            if inFlightCleared {
                // 隐私模式、关闭提醒或删除账号的清理可能先于在途 add 完成；完成后再清理一次，避免残留旧隐私正文。
                await client.removeNotifications(accountKey: identity.key)
            }
            log(.info, .quota, "quota alert accepted account=\(Redact.account(identity.key))")
        } catch {
            for limit in candidates {
                let key = QuotaAlertPolicy.windowKey(limit, app: observation.raw.app)
                account.windows[key]?.submission = nil
                account.windows[key]?.retryID = requestID
                account.windows[key]?.retryAfter = now().addingTimeInterval(QuotaAlertPolicy.retryInterval)
            }
            payload?.accounts[identity.key] = account
            _ = await save()
            lastError = Redact.error(error)
            log(.error, .quota, "quota alert submission failed: \(Redact.error(error))")
        }
    }

    private func makeMessage(
        _ observation: QuotaAlertObservation, limits: [QuotaLimit], context: QuotaAlertDisplayContext,
        identity: QuotaAlertIdentity, requestID: UUID
    ) -> QuotaNotificationMessage {
        let account = displayAccount(context)
        let lines = limits.map { limit in
            let label = limitLabel(limit, app: observation.raw.app)
            let percent = Self.percentText(remaining: limit.window.remainingPercent, threshold: preferences().threshold, translate: translate)
            let displayLimits = QuotaAlertPolicy.limits(in: observation.display, preferences: preferences())
            let displayReset = displayLimits.first(where: { $0.id == limit.id })?.window.resetsAt
            let reset = displayReset.flatMap { $0 > now() ? $0 : nil }
            let suffix = reset.map { " · " + resetHint($0, now()) } ?? ""
            return translate("\(label) remaining \(percent)", "\(label)剩余 \(percent)") + suffix
        }
        let provider = QuotaProviderDescriptor.descriptor(for: observation.raw.app)?.title ?? observation.raw.app.rawValue
        return QuotaNotificationMessage(
            identifier: SystemNotificationClient.prefix + requestID.uuidString,
            title: translate("\(provider) quota is low", "\(provider) 额度不足"),
            body: ([account] + lines).joined(separator: "\n"),
            sound: preferences().sound && permissionState?.sound == true, accountKey: identity.key,
            entryKey: QuotaAlertIdentity.digest([observation.entry])
        )
    }

    private func limitLabel(_ limit: QuotaLimit, app: QuotaApp) -> String {
        if app == .cursor { return limit.displayName ?? translate("Billing cycle quota", "计费周期额度") }
        if limit.id == "command-code-monthly" { return translate("Monthly credits", "月额度") }
        let period: String
        switch limit.kind {
        case .fiveHour:
            period = app == .claude ? translate("Current session", "当前会话") : translate("5-hour quota", "5 小时额度")
        case .weekly, .modelWeekly: period = translate("Weekly quota", "周额度")
        case .unknown: period = translate("Quota", "额度")
        }
        if app == .antigravity {
            let group = limit.id.hasPrefix("gemini-") ? "Gemini" : "Claude"
            return "\(group) \(period)"
        }
        if limit.kind == .modelWeekly, let name = limit.displayName { return "\(name) \(period)" }
        return period
    }

    static func percentText(remaining: Double, threshold: Int, translate: @MainActor (String, String) -> String = tr) -> String {
        if remaining > 0 && remaining < 0.1 { return translate("below 0.1%", "低于 0.1%") }
        let rounded = (remaining * 10).rounded() / 10
        if remaining < Double(threshold), rounded >= Double(threshold) {
            return translate("below \(threshold)%", "低于 \(threshold)%")
        }
        return String(format: rounded == rounded.rounded() ? "%.0f%%" : "%.1f%%", rounded)
    }

    func rebuild(entries: [String]) async {
        guard storagePaused, !isRebuilding, !stopping else { return }
        isRebuilding = true
        queue.removeAll()
        defer { isRebuilding = false }
        await worker?.value
        guard !stopping else { return }
        do {
            payload = try await store.rebuild(entries: entries)
            markInitialized()
            fatalStorageError = false
            storagePaused = false
            nextStorageRetry = nil
            processed.removeAll()
            recordCount = 0
            fileSize = await store.fileSize()
            log(.info, .persistence, "quota alert history rebuilt with baseline")
        } catch { pauseStorage(error, fatal: true) }
    }

    /// 不等待系统回调；已经安全保存的 prepared 在重启后继续抑制重复。
    func suspendForTermination() {
        stopping = true
        queue.removeAll()
    }

    func resumeAfterCancelledTermination() { stopping = false }

    // 测试等待持有任务，不启动系统采集或真实通知。
    func waitUntilIdle() async {
        await worker?.value
        await cleanup?.value
    }
}
