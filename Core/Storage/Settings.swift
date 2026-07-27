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
}

@Observable
@MainActor
final class SettingsStore {
    static let shared = SettingsStore()

    private let defaults: UserDefaults

    // 主 Provider 的全局 / 菜单栏 / 悬浮窗显示配置。
    // 统一按 QuotaApp 索引，新增 Provider 时不再扩三组平行字段。
    var providerDisplaySettings: [QuotaApp: ProviderDisplaySettings] {
        didSet { saveProviderDisplaySettings() }
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
    var showGrok: Bool {
        get { isProviderEnabled(.grok) }
        set { setProviderEnabled(newValue, for: .grok) }
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
    var menuBarShowGrok: Bool {
        get { isProviderShownInMenuBar(.grok) }
        set { setProviderShownInMenuBar(newValue, for: .grok) }
    }

    // 菜单栏
    var menuBarWindow: MenuBarWindowChoice { didSet { defaults.set(menuBarWindow.rawValue, forKey: Keys.menuBarWindow) } }

    // 悬浮窗（占位，M8 接）
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
    var floatingShowGrok: Bool {
        get { isProviderShownInFloatingHUD(.grok) }
        set { setProviderShownInFloatingHUD(newValue, for: .grok) }
    }

    // 刷新
    var quotaInterval: QuotaIntervalChoice { didSet { defaults.set(quotaInterval.rawValue, forKey: Keys.quotaInterval) } }
    var usageInterval: UsageIntervalChoice { didSet { defaults.set(usageInterval.rawValue, forKey: Keys.usageInterval) } }
    var resetTimeDisplay: ResetTimeDisplay { didSet { defaults.set(resetTimeDisplay.rawValue, forKey: Keys.resetTimeDisplay) } }

    /// 是否在 Popover 中显示 OpenAI / Anthropic 服务状态圆点
    var showServiceStatus: Bool { didSet { defaults.set(showServiceStatus, forKey: Keys.showServiceStatus) } }

    // 通用
    var appLanguage: AppLanguage { didSet { defaults.set(appLanguage.rawValue, forKey: Keys.appLanguage) } }
    var launchAtLogin: Bool { didSet { defaults.set(launchAtLogin, forKey: Keys.launchAtLogin) } }

    /// 隐私模式：Popover 中主账号邮箱、Codex 副账号名称均隐藏
    var privacyMode: Bool { didSet { defaults.set(privacyMode, forKey: Keys.privacyMode) } }

    /// 是否已经向用户解释过"接下来会出现 Keychain 授权弹窗"
    var didShowKeychainPrompt: Bool {
        didSet { defaults.set(didShowKeychainPrompt, forKey: Keys.didShowKeychainPrompt) }
    }

    /// 是否已经完成首次启动引导
    var didCompleteOnboarding: Bool {
        didSet { defaults.set(didCompleteOnboarding, forKey: Keys.didCompleteOnboarding) }
    }

    private init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        providerDisplaySettings = Self.loadProviderDisplaySettings(defaults: defaults)
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
        showServiceStatus = defaults.object(forKey: Keys.showServiceStatus) as? Bool ?? true
        // 通用：launchAtLogin 以系统当前注册状态为准
        let langRaw = defaults.string(forKey: Keys.appLanguage) ?? AppLanguage.system.rawValue
        appLanguage = AppLanguage(rawValue: langRaw) ?? .system
        launchAtLogin = Self.isLaunchAtLoginOn(SMAppService.mainApp.status)
        privacyMode = defaults.object(forKey: Keys.privacyMode) as? Bool ?? true
        didShowKeychainPrompt = defaults.object(forKey: Keys.didShowKeychainPrompt) as? Bool ?? false
        didCompleteOnboarding = defaults.object(forKey: Keys.didCompleteOnboarding) as? Bool ?? false
        saveProviderDisplaySettings()
    }

    func isProviderEnabled(_ app: QuotaApp) -> Bool {
        providerDisplaySettings[app, default: .enabledByDefault].enabled
    }

    func setProviderEnabled(_ enabled: Bool, for app: QuotaApp) {
        var settings = providerDisplaySettings[app, default: .enabledByDefault]
        settings.enabled = enabled
        providerDisplaySettings[app] = settings
    }

    func isProviderShownInMenuBar(_ app: QuotaApp) -> Bool {
        providerDisplaySettings[app, default: .enabledByDefault].menuBar
    }

    func setProviderShownInMenuBar(_ shown: Bool, for app: QuotaApp) {
        var settings = providerDisplaySettings[app, default: .enabledByDefault]
        settings.menuBar = shown
        providerDisplaySettings[app] = settings
    }

    func isProviderShownInFloatingHUD(_ app: QuotaApp) -> Bool {
        providerDisplaySettings[app, default: .enabledByDefault].floatingHUD
    }

    func setProviderShownInFloatingHUD(_ shown: Bool, for app: QuotaApp) {
        var settings = providerDisplaySettings[app, default: .enabledByDefault]
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
                result[app] = .enabledByDefault
            }
            return result
        }

        // 第一次升级到统一结构时读取旧 key；Antigravity 没有旧值，按计划默认开启。
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
            .antigravity: .enabledByDefault,
            .grok: .enabledByDefault,
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
        static let showServiceStatus = "ccbar.settings.showServiceStatus"
        static let launchAtLogin = "ccbar.settings.launchAtLogin"
        static let appLanguage = "ccbar.settings.appLanguage"
        static let privacyMode = "ccbar.settings.privacyMode"
        static let didShowKeychainPrompt = "ccbar.settings.didShowKeychainPrompt"
        static let didCompleteOnboarding = "ccbar.settings.didCompleteOnboarding"
        static let floatingFrameX = "ccbar.settings.floatingFrame.x"
        static let floatingFrameY = "ccbar.settings.floatingFrame.y"
        static let floatingFrameW = "ccbar.settings.floatingFrame.w"
        static let floatingFrameH = "ccbar.settings.floatingFrame.h"
    }
}
