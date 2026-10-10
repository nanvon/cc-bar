import CoreGraphics
import Foundation
import Observation
import ServiceManagement

enum QuotaIntervalChoice: String, CaseIterable, Identifiable {
    case m1
    case m2
    case m3
    case m5
    case m10

    var id: String { rawValue }

    var seconds: TimeInterval? {
        switch self {
        case .m1: return 60
        case .m2: return 2 * 60
        case .m3: return 3 * 60
        case .m5: return 5 * 60
        case .m10: return 10 * 60
        }
    }

    var displayName: String {
        switch self {
        case .m1: return "1 分钟"
        case .m2: return "2 分钟"
        case .m3: return "3 分钟"
        case .m5: return "5 分钟"
        case .m10: return "10 分钟"
        }
    }
}

enum UsageIntervalChoice: String, CaseIterable, Identifiable {
    case m1
    case m2
    case m3
    case m5
    case m10

    var id: String { rawValue }

    var seconds: TimeInterval {
        switch self {
        case .m1: return 60
        case .m2: return 2 * 60
        case .m3: return 3 * 60
        case .m5: return 5 * 60
        case .m10: return 10 * 60
        }
    }

    var displayName: String {
        switch self {
        case .m1: return "1 分钟"
        case .m2: return "2 分钟"
        case .m3: return "3 分钟"
        case .m5: return "5 分钟"
        case .m10: return "10 分钟"
        }
    }
}

enum ResetTimeDisplay: String, CaseIterable, Identifiable {
    case relative
    case absolute

    var id: String { rawValue }
}

enum MenuBarWindowChoice: String, CaseIterable, Identifiable {
    case primary
    case weekly
    case both

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .primary: return "主要额度"
        case .weekly: return "WK 窗口"
        case .both: return "两者都显示"
        }
    }
}

struct ProviderDisplaySettings: Sendable, Codable, Equatable {
    var enabled: Bool
    var menuBar: Bool
    var floatingHUD: Bool

    static let enabledByDefault = ProviderDisplaySettings(
        enabled: true,
        menuBar: true,
        floatingHUD: true
    )

    /// Cursor 与 Command Code 首次出现时保持关闭；只有用户主动开启后，
    /// 才会进入远端刷新链路，避免未配置的机器产生后台失败状态。
    /// Antigravity 默认开启（云端凭据直连，无本地进程依赖）。
    ///
    /// Command Code 的 `menuBar` / `floatingHUD` 刻意留 true，与 Cursor 的三项全 false 不同：
    /// 子开关只在 `enabled` 为真时才生效（见 `effectiveMenuBarVisibility` /
    /// `effectiveFloatingVisibility`），所以关闭状态下两者行为完全一致；差别在用户后来打开
    /// 总开关的那一刻——Command Code 直接出现在菜单栏和悬浮窗，Cursor 还要再开两个子开关。
    /// 这是有意的：Cursor 默认不替用户决定菜单栏和悬浮窗展示位。
    /// 改这两个值会改变已装机用户开启 Provider 后的首屏，不要当成笔误「对齐」掉。
    static func defaults(for app: QuotaApp) -> ProviderDisplaySettings {
        switch app {
        case .codex, .claude, .antigravity:
            enabledByDefault
        case .cursor:
            ProviderDisplaySettings(enabled: false, menuBar: false, floatingHUD: false)
        case .commandCode:
            ProviderDisplaySettings(enabled: false, menuBar: true, floatingHUD: true)
        }
    }
}

/// 服务顺序里的一项：额度服务，或只有用量的服务（Pi / OpenCode / DSH）。
/// Codex / Claude Code / Cursor 在额度和用量里是同一个服务，只记 `.quota` 一项。
/// 持久化用 rawValue，与 `QuotaApp` / `UsageApp` 的 rawValue 相同。
nonisolated enum ServiceOrderItem: Hashable, Sendable {
    case quota(QuotaApp)
    case usage(UsageApp)

    /// 没有对应额度服务的用量数据源，按 `UsageApp` 声明顺序。
    static var usageOnlyApps: [UsageApp] {
        let mapped = Set(QuotaApp.allCases.compactMap(\.usageApp))
        return UsageApp.allCases.filter { !mapped.contains($0) }
    }

    init?(rawValue: String) {
        if let app = QuotaApp(rawValue: rawValue) {
            self = .quota(app)
        } else if let app = UsageApp(rawValue: rawValue), Self.usageOnlyApps.contains(app) {
            self = .usage(app)
        } else {
            return nil
        }
    }

    var rawValue: String {
        switch self {
        case .quota(let app): return app.rawValue
        case .usage(let app): return app.rawValue
        }
    }

    /// 主窗口统计用的数据源；没有用量的额度服务为 nil。
    var usageApp: UsageApp? {
        switch self {
        case .quota(let app): return app.usageApp
        case .usage(let app): return app
        }
    }
}

enum CommandCodeCredentialPreference: String, CaseIterable, Identifiable, Codable {
    case automatic
    case manual

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .automatic: return "自动（推荐）"
        case .manual: return "手动 API Key"
        }
    }
}

@Observable
@MainActor
final class SettingsStore {
    static let shared = SettingsStore()

    private let defaults: UserDefaults

    // 主 Provider 的全局 / 菜单栏 / 悬浮窗显示配置。
    // 统一按 QuotaApp 索引，新增 Provider 时不再扩三组平行字段。
    var providerDisplaySettings: [QuotaApp: ProviderDisplaySettings] {
        didSet {
            saveProviderDisplaySettings()
            if QuotaApp.allCases.contains(where: { oldValue[$0]?.enabled != providerDisplaySettings[$0]?.enabled }) {
                quotaAlertRuntimeVersion &+= 1
            }
        }
    }

    /// 全部服务的展示顺序（设置页拖拽写入）：额度服务与只有用量的 Pi / OpenCode / DSH 混排。
    /// 默认额度服务按 `QuotaProviderDescriptor.allProviders`，再接 Pi / OpenCode / DSH。
    /// 设置列表读全部；菜单栏 / Popover / 悬浮窗只取额度服务，主窗口统计只取有用量的服务。
    var serviceOrder: [ServiceOrderItem] {
        didSet { saveServiceOrder() }
    }

    // 统计页按服务统计的显示配置；本地服务默认全开，Cursor 远端服务默认关闭。
    var usageServiceVisibility: [UsageApp: Bool] {
        didSet { saveUsageServiceVisibility() }
    }

    // 运行时 Cursor 账号可用性，由 AppState 的账号检测同步，不持久化。
    // 乐观初值 true：启动瞬间 loadCursor 还没跑完，先按上次偏好渲染，避免统计页闪一下空白。
    var cursorAccountDetected: Bool = true

    // 运行时 Command Code 账号可用性，由 AppState 的账号检测同步，不持久化。
    var commandCodeAccountDetected: Bool = true

    // Command Code 凭据来源偏好
    var commandCodeCredentialPreference: CommandCodeCredentialPreference {
        didSet { defaults.set(commandCodeCredentialPreference.rawValue, forKey: Keys.commandCodeCredentialPreference) }
    }

    // 兼容现有调用方的语义化入口。
    var showCodex: Bool {
        get { isProviderEnabled(.codex) }
        set { setProviderEnabled(newValue, for: .codex) }
    }
    var showClaude: Bool {
        get { isProviderEnabled(.claude) }
        set { setProviderEnabled(newValue, for: .claude) }
    }
    var showAntigravity: Bool {
        get { isProviderEnabled(.antigravity) }
        set { setProviderEnabled(newValue, for: .antigravity) }
    }
    var menuBarShowCodex: Bool {
        get { isProviderShownInMenuBar(.codex) }
        set { setProviderShownInMenuBar(newValue, for: .codex) }
    }
    var menuBarShowClaude: Bool {
        get { isProviderShownInMenuBar(.claude) }
        set { setProviderShownInMenuBar(newValue, for: .claude) }
    }
    var menuBarShowAntigravity: Bool {
        get { isProviderShownInMenuBar(.antigravity) }
        set { setProviderShownInMenuBar(newValue, for: .antigravity) }
    }

    // 菜单栏
    var menuBarWindow: MenuBarWindowChoice { didSet { defaults.set(menuBarWindow.rawValue, forKey: Keys.menuBarWindow) } }

    // 悬浮窗
    var floatingEnabled: Bool { didSet { defaults.set(floatingEnabled, forKey: Keys.floatingEnabled) } }
    var floatingShowCodex: Bool {
        get { isProviderShownInFloatingHUD(.codex) }
        set { setProviderShownInFloatingHUD(newValue, for: .codex) }
    }
    var floatingShowClaude: Bool {
        get { isProviderShownInFloatingHUD(.claude) }
        set { setProviderShownInFloatingHUD(newValue, for: .claude) }
    }
    var floatingShowAntigravity: Bool {
        get { isProviderShownInFloatingHUD(.antigravity) }
        set { setProviderShownInFloatingHUD(newValue, for: .antigravity) }
    }

    // 刷新
    var quotaInterval: QuotaIntervalChoice { didSet { defaults.set(quotaInterval.rawValue, forKey: Keys.quotaInterval) } }
    var usageInterval: UsageIntervalChoice { didSet { defaults.set(usageInterval.rawValue, forKey: Keys.usageInterval) } }
    var resetTimeDisplay: ResetTimeDisplay { didSet { defaults.set(resetTimeDisplay.rawValue, forKey: Keys.resetTimeDisplay) } }

    /// 统计页排行口径（默认 Tokens），见 `StatsRankMetric`。
    var statsRankMetric: StatsRankMetric { didSet { defaults.set(statsRankMetric.rawValue, forKey: Keys.statsRankMetric) } }

    /// 额度用满预估是否计入 Pi / OpenCode 里使用 Codex 订阅的用量（默认只算 Codex CLI）。
    /// 只影响展示：周期桶始终按来源 Agent 分别归集，切换不需要重建。
    var cycleIncludesOtherAgents: Bool {
        didSet { defaults.set(cycleIncludesOtherAgents, forKey: Keys.cycleIncludesOtherAgents) }
    }

    /// 是否在 Popover 中显示 OpenAI / Anthropic 服务状态圆点
    var showServiceStatus: Bool { didSet { defaults.set(showServiceStatus, forKey: Keys.showServiceStatus) } }

    // 通用
    var appLanguage: AppLanguage { didSet { defaults.set(appLanguage.rawValue, forKey: Keys.appLanguage) } }
    var launchAtLogin: Bool { didSet { defaults.set(launchAtLogin, forKey: Keys.launchAtLogin) } }

    /// 截图隐私模式：全局隐藏账号、项目及对话身份；保留真实用量统计。
    var privacyMode: Bool { didSet { defaults.set(privacyMode, forKey: Keys.privacyMode) } }

    // 系统授权状态不持久化；此版本号仅用于丢弃设置变化前开始的额度请求。
    private(set) var quotaAlertRuntimeVersion: UInt64 = 0
    var quotaAlertsEnabled: Bool {
        didSet { saveQuotaAlertPreference(quotaAlertsEnabled, key: "quotaAlertsEnabled") }
    }
    var quotaAlertThresholdPercent: Int {
        didSet { saveQuotaAlertPreference(quotaAlertThresholdPercent, key: "quotaAlertThresholdPercent") }
    }
    var quotaAlertFiveHourEnabled: Bool {
        didSet { saveQuotaAlertPreference(quotaAlertFiveHourEnabled, key: "quotaAlertFiveHourEnabled") }
    }
    var quotaAlertWeeklyEnabled: Bool {
        didSet { saveQuotaAlertPreference(quotaAlertWeeklyEnabled, key: "quotaAlertWeeklyEnabled") }
    }
    var quotaAlertBillingCycleEnabled: Bool {
        didSet { saveQuotaAlertPreference(quotaAlertBillingCycleEnabled, key: "quotaAlertBillingCycleEnabled") }
    }
    var quotaAlertSoundEnabled: Bool {
        didSet { saveQuotaAlertPreference(quotaAlertSoundEnabled, key: "quotaAlertSoundEnabled") }
    }
    var quotaAlertStoreInitialized: Bool {
        get { defaults.bool(forKey: "ccbar.settings.quotaAlertStoreInitialized.v1") }
        set { defaults.set(newValue, forKey: "ccbar.settings.quotaAlertStoreInitialized.v1") }
    }

    var quotaAlertPreferences: QuotaAlertPreferences {
        QuotaAlertPreferences(
            enabled: quotaAlertsEnabled,
            threshold: QuotaAlertPreferences.validThreshold(quotaAlertThresholdPercent),
            fiveHour: quotaAlertFiveHourEnabled, weekly: quotaAlertWeeklyEnabled,
            billingCycle: quotaAlertBillingCycleEnabled, sound: quotaAlertSoundEnabled
        )
    }

    private func saveQuotaAlertPreference(_ value: Any, key: String) {
        defaults.set(value, forKey: "ccbar.settings.\(key)")
        quotaAlertRuntimeVersion &+= 1
    }

    /// Sparkle 管理检查偏好；旧版开关只作为首次迁移的兜底，保留用户关闭的选择。
    var autoCheckForUpdates: Bool {
        defaults.object(forKey: "SUEnableAutomaticChecks") as? Bool
            ?? defaults.object(forKey: Keys.autoCheckForUpdates) as? Bool
            ?? true
    }

    /// 详细日志(默认关)。打开后 `AppLog` 的 debug 级别才落盘,排查完建议关掉。
    /// 与 `privacyMode` 无关——那是界面打码,日志脱敏始终无条件生效。
    var verboseLogging: Bool {
        didSet {
            defaults.set(verboseLogging, forKey: Keys.verboseLogging)
            AppLog.shared.setVerbose(verboseLogging)
        }
    }

    /// 是否已经向用户解释过"接下来会出现 Keychain 授权弹窗"
    var didShowKeychainPrompt: Bool {
        didSet { defaults.set(didShowKeychainPrompt, forKey: Keys.didShowKeychainPrompt) }
    }

    /// 是否已经完成首次启动引导
    var didCompleteOnboarding: Bool {
        didSet { defaults.set(didCompleteOnboarding, forKey: Keys.didCompleteOnboarding) }
    }

    /// 本次启动前从未保存过 Provider 显示设置（新安装）。只在内存里判断，不持久化；
    /// 用于首次启动按凭据检测结果收敛默认开关，已装机用户不受影响。
    let isFreshInstall: Bool

    private init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        isFreshInstall = defaults.data(forKey: Keys.providerDisplaySettings) == nil
            && defaults.object(forKey: Keys.showCodex) == nil
        providerDisplaySettings = Self.loadProviderDisplaySettings(defaults: defaults)
        serviceOrder = Self.loadServiceOrder(defaults: defaults)
        usageServiceVisibility = Self.loadUsageServiceVisibility(defaults: defaults)
        // 菜单栏
        let mbWindowRaw = defaults.string(forKey: Keys.menuBarWindow) ?? MenuBarWindowChoice.primary.rawValue
        if mbWindowRaw == "fiveHour" {
            menuBarWindow = .primary
            defaults.set(MenuBarWindowChoice.primary.rawValue, forKey: Keys.menuBarWindow)
        } else {
            menuBarWindow = MenuBarWindowChoice(rawValue: mbWindowRaw) ?? .primary
        }
        // 悬浮窗
        floatingEnabled = defaults.object(forKey: Keys.floatingEnabled) as? Bool ?? false
        // 刷新
        let qiRaw = defaults.string(forKey: Keys.quotaInterval) ?? QuotaIntervalChoice.m2.rawValue
        quotaInterval = QuotaIntervalChoice(rawValue: qiRaw) ?? .m2
        let uiRaw = defaults.string(forKey: Keys.usageInterval) ?? UsageIntervalChoice.m5.rawValue
        usageInterval = UsageIntervalChoice(rawValue: uiRaw) ?? .m5
        let rtdRaw = defaults.string(forKey: Keys.resetTimeDisplay) ?? ResetTimeDisplay.relative.rawValue
        resetTimeDisplay = ResetTimeDisplay(rawValue: rtdRaw) ?? .relative
        let srmRaw = defaults.string(forKey: Keys.statsRankMetric) ?? StatsRankMetric.tokens.rawValue
        statsRankMetric = StatsRankMetric(rawValue: srmRaw) ?? .tokens
        cycleIncludesOtherAgents = defaults.object(forKey: Keys.cycleIncludesOtherAgents) as? Bool ?? false
        showServiceStatus = defaults.object(forKey: Keys.showServiceStatus) as? Bool ?? true
        // 通用：launchAtLogin 以系统当前注册状态为准
        let langRaw = defaults.string(forKey: Keys.appLanguage) ?? AppLanguage.system.rawValue
        appLanguage = AppLanguage(rawValue: langRaw) ?? .system
        launchAtLogin = Self.isLaunchAtLoginOn(SMAppService.mainApp.status)
        privacyMode = defaults.object(forKey: Keys.privacyMode) as? Bool ?? false
        quotaAlertsEnabled = defaults.object(forKey: "ccbar.settings.quotaAlertsEnabled") as? Bool
            ?? defaults.object(forKey: "ccbar.settings.codexQuotaAlertsEnabled") as? Bool ?? false
        quotaAlertThresholdPercent = QuotaAlertPreferences.validThreshold(
            defaults.object(forKey: "ccbar.settings.quotaAlertThresholdPercent") as? Int ?? 20
        )
        let alertFiveHour = defaults.object(forKey: "ccbar.settings.quotaAlertFiveHourEnabled") as? Bool ?? true
        let alertWeekly = defaults.object(forKey: "ccbar.settings.quotaAlertWeeklyEnabled") as? Bool ?? true
        let alertBillingCycle = defaults.object(forKey: "ccbar.settings.quotaAlertBillingCycleEnabled") as? Bool ?? true
        quotaAlertFiveHourEnabled = alertFiveHour || (!alertWeekly && !alertBillingCycle)
        quotaAlertWeeklyEnabled = alertWeekly
        quotaAlertBillingCycleEnabled = alertBillingCycle
        quotaAlertSoundEnabled = defaults.object(forKey: "ccbar.settings.quotaAlertSoundEnabled") as? Bool ?? false
        verboseLogging = defaults.object(forKey: Keys.verboseLogging) as? Bool ?? false
        didShowKeychainPrompt = defaults.object(forKey: Keys.didShowKeychainPrompt) as? Bool ?? false
        didCompleteOnboarding = defaults.object(forKey: Keys.didCompleteOnboarding) as? Bool ?? false
        let ccpRaw = defaults.string(forKey: Keys.commandCodeCredentialPreference) ?? CommandCodeCredentialPreference.automatic.rawValue
        commandCodeCredentialPreference = CommandCodeCredentialPreference(rawValue: ccpRaw) ?? .automatic
        Self.mergeServiceSwitches(providers: &providerDisplaySettings, usage: &usageServiceVisibility)
        saveProviderDisplaySettings()
        saveServiceOrder()
        saveUsageServiceVisibility()
    }

    /// 默认顺序：额度服务与 `QuotaProviderDescriptor.allProviders` 一致，再接只有用量的服务。
    static var defaultServiceOrder: [ServiceOrderItem] {
        QuotaProviderDescriptor.allProviders.map { .quota($0.app) }
            + ServiceOrderItem.usageOnlyApps.map { .usage($0) }
    }

    /// 补齐后的全部服务顺序；设置页服务列表按这里排。
    var orderedServices: [ServiceOrderItem] {
        Self.normalizedServiceOrder(serviceOrder)
    }

    /// 按 `serviceOrder` 返回额度 Provider 描述符；未知 / 缺失项按默认序补齐。
    var orderedProviders: [QuotaProviderDescriptor] {
        let byApp = Dictionary(uniqueKeysWithValues: QuotaProviderDescriptor.allProviders.map { ($0.app, $0) })
        return orderedServices.compactMap { item in
            if case .quota(let app) = item { return byApp[app] }
            return nil
        }
    }

    var orderedMenuBarProviders: [QuotaProviderDescriptor] {
        orderedProviders.filter(\.supportsMenuBar)
    }

    var orderedFloatingProviders: [QuotaProviderDescriptor] {
        orderedProviders.filter(\.supportsFloatingHUD)
    }

    /// 按给定顺序重排；忽略非法值，缺省服务追加到末尾。
    func reorderServices(_ ordered: [ServiceOrderItem]) {
        let next = Self.normalizedServiceOrder(ordered)
        guard next != serviceOrder else { return }
        serviceOrder = next
    }

    /// 将 `source` 挪到 `target` 之前。
    func moveService(_ source: ServiceOrderItem, before target: ServiceOrderItem) {
        moveService(source, target: target, after: false)
    }

    /// 将 `source` 挪到 `target` 之后。
    func moveService(_ source: ServiceOrderItem, after target: ServiceOrderItem) {
        moveService(source, target: target, after: true)
    }

    private func moveService(_ source: ServiceOrderItem, target: ServiceOrderItem, after: Bool) {
        var order = orderedServices
        guard let from = order.firstIndex(of: source),
              let to = order.firstIndex(of: target),
              from != to else { return }
        order.remove(at: from)
        let targetIndex = order.firstIndex(of: target) ?? min(to, order.count)
        let insertAt = min(targetIndex + (after ? 1 : 0), order.count)
        order.insert(source, at: insertAt)
        reorderServices(order)
    }

    static func normalizedServiceOrder(_ preferred: [ServiceOrderItem]) -> [ServiceOrderItem] {
        let defaults = defaultServiceOrder
        var seen = Set<ServiceOrderItem>()
        var result: [ServiceOrderItem] = []
        for item in preferred where defaults.contains(item) && !seen.contains(item) {
            result.append(item)
            seen.insert(item)
        }
        for item in defaults where !seen.contains(item) {
            result.append(item)
        }
        return result
    }

    private static func loadServiceOrder(defaults: UserDefaults) -> [ServiceOrderItem] {
        if let raw = defaults.array(forKey: Keys.serviceOrder) as? [String] {
            return normalizedServiceOrder(raw.compactMap(ServiceOrderItem.init(rawValue:)))
        }
        return defaultServiceOrder
    }

    private func saveServiceOrder() {
        defaults.set(serviceOrder.map(\.rawValue), forKey: Keys.serviceOrder)
    }

    func isProviderEnabled(_ app: QuotaApp) -> Bool {
        providerDisplaySettings[app, default: .defaults(for: app)].enabled
    }

    /// 设置页「开启」开关：一个服务一个开关，同时管额度（Provider）和用量（统计服务）。
    /// 额度相关调用方仍读 `isProviderEnabled`，统计页仍读 `isUsageServiceVisible`，两边由这里保持一致。
    func setServiceEnabled(_ enabled: Bool, for app: QuotaApp) {
        setProviderEnabled(enabled, for: app)
        if let usageApp = app.usageApp {
            setUsageServiceVisible(enabled, for: usageApp)
        }
    }

    /// 旧版额度开关和统计开关可以分开设置。合并成一个开关后，两者不一致时按
    /// 「任一项开着就算开启」处理，避免用户已有的额度卡片或统计数据突然看不到。
    /// 每次启动都跑一遍；两项一致时不改动，结果幂等。
    private static func mergeServiceSwitches(
        providers: inout [QuotaApp: ProviderDisplaySettings],
        usage: inout [UsageApp: Bool]
    ) {
        for app in QuotaApp.allCases {
            guard let usageApp = app.usageApp else { continue }
            var settings = providers[app, default: .defaults(for: app)]
            let visible = usage[usageApp, default: usageApp == .cursor ? false : true]
            let merged = settings.enabled || visible
            settings.enabled = merged
            providers[app] = settings
            usage[usageApp] = merged
        }
    }

    func setProviderEnabled(_ enabled: Bool, for app: QuotaApp) {
        var settings = providerDisplaySettings[app, default: .defaults(for: app)]
        settings.enabled = enabled
        providerDisplaySettings[app] = settings
    }

    func isProviderShownInMenuBar(_ app: QuotaApp) -> Bool {
        providerDisplaySettings[app, default: .defaults(for: app)].menuBar
    }

    func setProviderShownInMenuBar(_ shown: Bool, for app: QuotaApp) {
        var settings = providerDisplaySettings[app, default: .defaults(for: app)]
        settings.menuBar = shown
        providerDisplaySettings[app] = settings
    }

    func isProviderShownInFloatingHUD(_ app: QuotaApp) -> Bool {
        providerDisplaySettings[app, default: .defaults(for: app)].floatingHUD
    }

    func setProviderShownInFloatingHUD(_ shown: Bool, for app: QuotaApp) {
        var settings = providerDisplaySettings[app, default: .defaults(for: app)]
        settings.floatingHUD = shown
        providerDisplaySettings[app] = settings
    }

    func effectiveMenuBarVisibility(for app: QuotaApp) -> Bool {
        isProviderEnabled(app) && isProviderShownInMenuBar(app)
    }

    func effectiveFloatingVisibility(for app: QuotaApp) -> Bool {
        isProviderEnabled(app) && isProviderShownInFloatingHUD(app)
    }

    private static func loadProviderDisplaySettings(
        defaults: UserDefaults
    ) -> [QuotaApp: ProviderDisplaySettings] {
        if let data = defaults.data(forKey: Keys.providerDisplaySettings),
           let stored = try? JSONDecoder().decode([String: ProviderDisplaySettings].self, from: data)
        {
            var result: [QuotaApp: ProviderDisplaySettings] = [:]
            for (raw, settings) in stored {
                if let app = QuotaApp(rawValue: raw) {
                    result[app] = settings
                }
            }
            for app in QuotaApp.allCases where result[app] == nil {
                result[app] = .defaults(for: app)
            }
            return result
        }

        // 第一次升级到统一结构时读取旧 key。
        return [
            .codex: ProviderDisplaySettings(
                enabled: defaults.object(forKey: Keys.showCodex) as? Bool ?? true,
                menuBar: defaults.object(forKey: Keys.menuBarShowCodex) as? Bool ?? true,
                floatingHUD: defaults.object(forKey: Keys.floatingShowCodex) as? Bool ?? true
            ),
            .claude: ProviderDisplaySettings(
                enabled: defaults.object(forKey: Keys.showClaude) as? Bool ?? true,
                menuBar: defaults.object(forKey: Keys.menuBarShowClaude) as? Bool ?? true,
                floatingHUD: defaults.object(forKey: Keys.floatingShowClaude) as? Bool ?? true
            ),
            .cursor: .defaults(for: .cursor),
        ]
    }

    private func saveProviderDisplaySettings() {
        let stored = Dictionary(uniqueKeysWithValues: providerDisplaySettings.map {
            ($0.key.rawValue, $0.value)
        })
        if let data = try? JSONEncoder().encode(stored) {
            defaults.set(data, forKey: Keys.providerDisplaySettings)
        }
    }

    // MARK: - Usage service visibility (Stats by-service)

    /// 该服务是否计入统计页(全站过滤:KPI / Token 拆分 / 按服务 / 按模型 / 每日用量 / 对话页)。
    /// 这里只反映用户偏好；设置页开关读它，保证卸载 / 退出 Cursor 后偏好不被静默改写。
    func isUsageServiceVisible(_ app: UsageApp) -> Bool {
        usageServiceVisibility[app, default: app == .cursor ? false : true]
    }

    /// 统计页实际采用的可见性：在用户偏好之上叠加运行时账号可用性。
    /// Cursor 没有本地日志，账号消失后远端缓存不会再更新，继续展示只会留下一条空服务行；
    /// 但偏好本身保留，用户重新登录 Cursor 后自动恢复，不需要再去设置页打开一次。
    func isUsageServiceEffectivelyVisible(_ app: UsageApp) -> Bool {
        guard isUsageServiceVisible(app) else { return false }
        return app == .cursor ? cursorAccountDetected : true
    }

    func setUsageServiceVisible(_ visible: Bool, for app: UsageApp) {
        usageServiceVisibility[app] = visible
    }

    /// 按全部服务的顺序返回可见统计服务；没有用量的额度服务（Antigravity / Command Code）跳过。
    /// Cursor 默认关闭；用户在设置页开启 Cursor 后，才会读取其远端用量缓存并进入统计页。
    var visibleUsageApps: [UsageApp] {
        orderedServices.compactMap(\.usageApp).filter { isUsageServiceEffectivelyVisible($0) }
    }

    private static func loadUsageServiceVisibility(
        defaults: UserDefaults
    ) -> [UsageApp: Bool] {
        var result: [UsageApp: Bool] = [:]
        if let data = defaults.data(forKey: Keys.usageServiceVisibility),
           let stored = try? JSONDecoder().decode([String: Bool].self, from: data)
        {
            for (raw, visible) in stored {
                if let app = UsageApp(rawValue: raw) {
                    result[app] = visible
                }
            }
        }
        for app in UsageApp.allCases where result[app] == nil {
            result[app] = app == .cursor ? false : true
        }
        return result
    }

    private func saveUsageServiceVisibility() {
        let stored = Dictionary(uniqueKeysWithValues: usageServiceVisibility.map {
            ($0.key.rawValue, $0.value)
        })
        if let data = try? JSONEncoder().encode(stored) {
            defaults.set(data, forKey: Keys.usageServiceVisibility)
        }
    }

    /// 把 `appLanguage` 解析为最终渲染语言。`.system` 看系统首选语言是否以 `zh` 开头。
    /// 不用 `Locale.current`:它返回的是 App 当前生效的本地化语言,工程未添加中文资源时会回退到开发语言 `en`,
    /// 导致即便系统设为中文也判定为英文。`Locale.preferredLanguages.first` 反映用户在系统设置中排首位的语言,
    /// 与 App 本地化无关,例如 `zh-Hans-CN` / `zh-Hant-TW`,前缀判断对简繁均成立。
    var resolvedLanguage: ResolvedLanguage {
        switch appLanguage {
        case .system:
            let code = Locale.preferredLanguages.first ?? "en"
            return code.hasPrefix("zh") ? .zh : .en
        case .zh: return .zh
        case .en: return .en
        }
    }

    // MARK: - Floating panel frame

    /// 悬浮窗 frame，nil 表示尚未拖动过；启动时由 controller 还原
    var floatingPanelFrame: CGRect? {
        get {
            guard
                let x = defaults.object(forKey: Keys.floatingFrameX) as? Double,
                let y = defaults.object(forKey: Keys.floatingFrameY) as? Double,
                let w = defaults.object(forKey: Keys.floatingFrameW) as? Double,
                let h = defaults.object(forKey: Keys.floatingFrameH) as? Double,
                w > 0, h > 0
            else { return nil }
            return CGRect(x: x, y: y, width: w, height: h)
        }
        set {
            if let r = newValue {
                defaults.set(Double(r.origin.x), forKey: Keys.floatingFrameX)
                defaults.set(Double(r.origin.y), forKey: Keys.floatingFrameY)
                defaults.set(Double(r.size.width), forKey: Keys.floatingFrameW)
                defaults.set(Double(r.size.height), forKey: Keys.floatingFrameH)
            } else {
                defaults.removeObject(forKey: Keys.floatingFrameX)
                defaults.removeObject(forKey: Keys.floatingFrameY)
                defaults.removeObject(forKey: Keys.floatingFrameW)
                defaults.removeObject(forKey: Keys.floatingFrameH)
            }
        }
    }

    // MARK: - Launch at login

    /// 当前系统记录的注册状态
    var launchAtLoginRegistered: Bool {
        Self.isLaunchAtLoginOn(SMAppService.mainApp.status)
    }

    /// 切换开机自启；失败时抛出原始错误
    func setLaunchAtLogin(_ enabled: Bool) throws {
        if enabled == launchAtLoginRegistered {
            launchAtLogin = enabled
            return
        }

        if enabled {
            try SMAppService.mainApp.register()
        } else {
            try SMAppService.mainApp.unregister()
        }
        syncLaunchAtLoginStatus()
    }

    /// 重新读取系统注册状态，避免 UserDefaults 与系统 Login Item 状态错位。
    func syncLaunchAtLoginStatus() {
        launchAtLogin = launchAtLoginRegistered
    }

    var launchAtLoginRequiresApproval: Bool {
        SMAppService.mainApp.status == .requiresApproval
    }

    private static func isLaunchAtLoginOn(_ status: SMAppService.Status) -> Bool {
        switch status {
        case .enabled, .requiresApproval:
            return true
        case .notRegistered, .notFound:
            return false
        @unknown default:
            return false
        }
    }

    private enum Keys {
        static let providerDisplaySettings = "ccbar.settings.providerDisplaySettings.v1"
        static let serviceOrder = "ccbar.settings.serviceOrder.v1"
        static let usageServiceVisibility = "ccbar.settings.usageServiceVisibility.v1"
        // 旧 key 仅用于首次迁移，后续不再写入。
        static let showCodex = "ccbar.settings.showCodex"
        static let showClaude = "ccbar.settings.showClaude"
        static let menuBarShowCodex = "ccbar.settings.menuBarShowCodex"
        static let menuBarShowClaude = "ccbar.settings.menuBarShowClaude"
        static let menuBarWindow = "ccbar.settings.menuBarWindow"
        static let floatingEnabled = "ccbar.settings.floatingEnabled"
        static let floatingShowCodex = "ccbar.settings.floatingShowCodex"
        static let floatingShowClaude = "ccbar.settings.floatingShowClaude"
        static let quotaInterval = "ccbar.settings.quotaInterval"
        static let usageInterval = "ccbar.settings.usageInterval"
        static let resetTimeDisplay = "ccbar.settings.resetTimeDisplay"
        static let statsRankMetric = "ccbar.settings.statsRankMetric"
        static let cycleIncludesOtherAgents = "ccbar.settings.cycleIncludesOtherAgents"
        static let showServiceStatus = "ccbar.settings.showServiceStatus"
        static let launchAtLogin = "ccbar.settings.launchAtLogin"
        static let appLanguage = "ccbar.settings.appLanguage"
        static let privacyMode = "ccbar.settings.privacyMode"
        static let autoCheckForUpdates = "ccbar.settings.autoCheckForUpdates"
        /// 与 `AppLog` 共用同一个 key:门面在 init 时直接读 UserDefaults,不能等 SettingsStore 建好。
        static let verboseLogging = AppLog.verboseLoggingDefaultsKey
        static let didShowKeychainPrompt = "ccbar.settings.didShowKeychainPrompt"
        static let didCompleteOnboarding = "ccbar.settings.didCompleteOnboarding"
        static let floatingFrameX = "ccbar.settings.floatingFrame.x"
        static let floatingFrameY = "ccbar.settings.floatingFrame.y"
        static let floatingFrameW = "ccbar.settings.floatingFrame.w"
        static let floatingFrameH = "ccbar.settings.floatingFrame.h"
        static let commandCodeCredentialPreference = "ccbar.settings.commandCodeCredentialPreference"
    }
}
