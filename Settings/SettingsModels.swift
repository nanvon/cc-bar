import SwiftUI

// MARK: - SettingsSidebarGroup

enum SettingsSidebarGroup: String, CaseIterable, Identifiable {
    case core
    case system

    var id: String { rawValue }

    var englishTitle: String {
        switch self {
        case .core: return "Workspace"
        case .system: return "Data & System"
        }
    }

    var chineseTitle: String {
        switch self {
        case .core: return "核心配置"
        case .system: return "数据与系统"
        }
    }

    var categories: [SettingsCategory] {
        SettingsCategory.allCases.filter { $0.sidebarGroup == self }
    }
}

// MARK: - SettingsCategory

enum SettingsCategory: String, CaseIterable, Identifiable {
    case services
    case display
    case alerts
    case statistics
    case network
    case general

    var id: String { rawValue }

    var sidebarGroup: SettingsSidebarGroup {
        switch self {
        case .services, .display, .alerts:
            return .core
        case .statistics, .network, .general:
            return .system
        }
    }

    var englishTitle: String {
        switch self {
        case .services: return "Services & Accounts"
        case .display: return "Display & Privacy"
        case .alerts: return "Quota Alerts"
        case .statistics: return "Statistics & Metering"
        case .network: return "Refresh & Network"
        case .general: return "General & About"
        }
    }

    var chineseTitle: String {
        switch self {
        case .services: return "服务与账号"
        case .display: return "显示与隐私"
        case .alerts: return "额度提醒"
        case .statistics: return "统计与计量"
        case .network: return "刷新与网络"
        case .general: return "通用与关于"
        }
    }

    var englishSubtitle: String {
        switch self {
        case .services: return "Manage detected AI services, display order, visibility and accounts."
        case .display: return "Customize Menu Bar, Popover, Floating HUD, reset time format and privacy."
        case .alerts: return "Get notified when remaining subscription quota drops below your threshold."
        case .statistics: return "Configure ranking metrics, units, cross-agent attribution and price history."
        case .network: return "Control background polling intervals, global proxy and Claude proxy routing."
        case .general: return "Language, startup behavior, diagnostic logs and software updates."
        }
    }

    var chineseSubtitle: String {
        switch self {
        case .services: return "管理已检测的 AI 服务、显示顺序、展示位置与扩展账号。"
        case .display: return "自定义菜单栏、弹出面板、桌面悬浮窗、重置时间与截图隐私。"
        case .alerts: return "在订阅剩余额度低于阈值时发送系统通知提醒。"
        case .statistics: return "设置统计口径、单位格式、跨 Agent 归属以及价格目录重算。"
        case .network: return "调整后台刷新频率、全局代理及 Claude 独立网络路由。"
        case .general: return "应用语言、开机自启、脱敏诊断日志与版本更新。"
        }
    }

    var icon: String {
        switch self {
        case .services: return "square.stack.3d.up"
        case .display: return "macwindow"
        case .alerts: return "bell"
        case .statistics: return "chart.bar"
        case .network: return "network"
        case .general: return "gearshape"
        }
    }
}

// MARK: - Search Index

struct SettingsSearchItem: Identifiable, Hashable {
    let id: String
    let category: SettingsCategory
    let sectionID: String
    let englishTitle: String
    let chineseTitle: String
    let englishSummary: String
    let chineseSummary: String
    let keywords: [String]

    @MainActor
    var localizedTitle: String { tr(englishTitle, chineseTitle) }

    @MainActor
    var localizedSummary: String { tr(englishSummary, chineseSummary) }

    @MainActor
    func matches(_ query: String) -> Bool {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !q.isEmpty else { return false }
        let haystacks = [
            englishTitle, chineseTitle,
            englishSummary, chineseSummary,
            category.englishTitle, category.chineseTitle
        ] + keywords
        return haystacks.contains { $0.lowercased().contains(q) }
    }
}

enum SettingsSearchCatalog {
    static let items: [SettingsSearchItem] = [
        // Services
        SettingsSearchItem(
            id: "services.manage",
            category: .services,
            sectionID: "services-detected",
            englishTitle: "Services & Accounts",
            chineseTitle: "服务开关与排序",
            englishSummary: "Codex, Claude Code, Antigravity, Cursor, Command Code, OpenCode Go, Pi, OpenCode, DSH",
            chineseSummary: "管理 Codex、Claude、Antigravity、Cursor、Pi 等服务开关与拖动排序",
            keywords: ["codex", "claude", "antigravity", "cursor", "command code", "opencode", "pi", "dsh", "account", "账号", "排序", "凭据", "auth"]
        ),
        SettingsSearchItem(
            id: "services.imported",
            category: .services,
            sectionID: "services-detected",
            englishTitle: "Additional Codex Accounts",
            chineseTitle: "导入其他 Codex 账号",
            englishSummary: "Import extra auth.json accounts to monitor quota in Popover",
            chineseSummary: "粘贴 auth.json 添加其他 Codex 账号并在弹出面板查看额度",
            keywords: ["codex", "import", "auth.json", "导入", "多账号", "reset credits", "额度重置"]
        ),
        // Display
        SettingsSearchItem(
            id: "display.menubar",
            category: .display,
            sectionID: "display-menubar",
            englishTitle: "Menu Bar Quota Period",
            chineseTitle: "菜单栏额度周期",
            englishSummary: "Choose Main, Weekly or Both in the macOS menu bar",
            chineseSummary: "选择菜单栏显示主额度、周额度或两者都显示",
            keywords: ["menu bar", "menubar", "菜单栏", "主额度", "周额度", "周期"]
        ),
        SettingsSearchItem(
            id: "display.popover",
            category: .display,
            sectionID: "display-popover",
            englishTitle: "Popover Display",
            chineseTitle: "弹出面板展示项",
            englishSummary: "Official status dot, recent conversations count and account email",
            chineseSummary: "官方状态圆点、最近对话条数与账号邮箱显示",
            keywords: ["popover", "弹出面板", "状态圆点", "最近对话", "邮箱", "email", "conversations"]
        ),
        SettingsSearchItem(
            id: "display.floating",
            category: .display,
            sectionID: "display-floating",
            englishTitle: "Floating HUD",
            chineseTitle: "桌面悬浮窗",
            englishSummary: "Show or hide the always-on-top desktop quota strip",
            chineseSummary: "开启或关闭桌面悬浮窗，并管理悬浮窗展示服务",
            keywords: ["floating", "hud", "悬浮窗", "桌面"]
        ),
        SettingsSearchItem(
            id: "display.privacy",
            category: .display,
            sectionID: "display-privacy",
            englishTitle: "Reset Time & Privacy Mode",
            chineseTitle: "重置时间与隐私模式",
            englishSummary: "Switch relative/exact reset times and hide names for screenshots",
            chineseSummary: "切换剩余时长/具体时间，开启隐私模式隐藏账号与项目名",
            keywords: ["privacy", "隐私", "截图", "reset", "重置时间", "剩余时长", "具体时间"]
        ),
        // Alerts
        SettingsSearchItem(
            id: "alerts.threshold",
            category: .alerts,
            sectionID: "alerts-main",
            englishTitle: "Quota Alerts & Threshold",
            chineseTitle: "低额度提醒与阈值",
            englishSummary: "Enable notifications and set remaining percentage threshold (5%–50%)",
            chineseSummary: "开启低额度系统通知并设置触发阈值（5%–50%）",
            keywords: ["alert", "notification", "提醒", "通知", "阈值", "低额度", "权限"]
        ),
        SettingsSearchItem(
            id: "alerts.windows",
            category: .alerts,
            sectionID: "alerts-windows",
            englishTitle: "Monitored Quota Windows & Sound",
            chineseTitle: "提醒窗口与声音",
            englishSummary: "5-hour session, weekly, billing cycle windows and notification sound",
            chineseSummary: "选择 5 小时、周额度、计费周期提醒范围及提示音",
            keywords: ["5小时", "周额度", "计费周期", "声音", "sound", "session", "weekly"]
        ),
        // Statistics
        SettingsSearchItem(
            id: "stats.metrics",
            category: .statistics,
            sectionID: "stats-metrics",
            englishTitle: "Ranking Metric & Token Units",
            chineseTitle: "排行口径与 Token 单位",
            englishSummary: "Rank by Tokens or Cost; format units as 万/亿 or k/M/B",
            chineseSummary: "按 Tokens 或费用排序，选择中文万/亿或英文 k/M/B 单位",
            keywords: ["ranking", "token", "cost", "排行", "口径", "单位", "费用", "万", "亿"]
        ),
        SettingsSearchItem(
            id: "stats.attribution",
            category: .statistics,
            sectionID: "stats-attribution",
            englishTitle: "Cross-Agent Subscription Attribution",
            chineseTitle: "跨 Agent 订阅用量归属",
            englishSummary: "Include Pi, OpenCode & DSH usage in Codex and Antigravity cycles",
            chineseSummary: "将 Pi、OpenCode、DSH 中的 Codex 与 Antigravity 用量计入主账号",
            keywords: ["pi", "opencode", "dsh", "codex", "antigravity", "归属", "订阅用量", "周期"]
        ),
        SettingsSearchItem(
            id: "stats.pi-speed",
            category: .statistics,
            sectionID: "stats-speed",
            englishTitle: "Pi Output Speed & Timing Plugin",
            chineseTitle: "估算 Pi 输出速度与计时插件",
            englishSummary: "Estimate speed from total duration or install the Pi timing extension",
            chineseSummary: "设置 Pi 速度估算及复制计时插件编写说明",
            keywords: ["pi", "speed", "timing", "输出速度", "计时插件", "extension"]
        ),
        SettingsSearchItem(
            id: "stats.maintenance",
            category: .statistics,
            sectionID: "stats-maintenance",
            englishTitle: "Price Catalog & Recalculate Usage",
            chineseTitle: "价格目录与重新计算用量",
            englishSummary: "Fetch latest model pricing rules and recompute historical usage",
            chineseSummary: "更新模型价格目录，按最新规则重算历史统计与周期用量",
            keywords: ["price", "pricing", "recalculate", "价格", "目录", "重算", "历史", "rescan"]
        ),
        // Network
        SettingsSearchItem(
            id: "network.polling",
            category: .network,
            sectionID: "network-polling",
            englishTitle: "Background Polling Intervals",
            chineseTitle: "后台刷新与日志扫描间隔",
            englishSummary: "Adjust quota refresh frequency and local log scan interval",
            chineseSummary: "设置额度轮询频率与本机对话日志扫描间隔",
            keywords: ["refresh", "polling", "interval", "scan", "刷新", "频率", "日志扫描", "后台"]
        ),
        SettingsSearchItem(
            id: "network.proxy",
            category: .network,
            sectionID: "network-proxy",
            englishTitle: "Network Proxy & Claude Proxy",
            chineseTitle: "全局代理与 Claude 专用代理",
            englishSummary: "Follow system or manual HTTP/SOCKS5 proxy, Claude direct mode and connection test",
            chineseSummary: "配置全局手动代理、Claude 独立代理或直连，并测试连接可达性",
            keywords: ["proxy", "http", "socks5", "claude", "direct", "代理", "直连", "网络", "端口", "连接测试"]
        ),
        // General
        SettingsSearchItem(
            id: "general.system",
            category: .general,
            sectionID: "general-system",
            englishTitle: "Language & Launch at Login",
            chineseTitle: "界面语言与开机自动启动",
            englishSummary: "Switch app language and manage macOS login item startup",
            chineseSummary: "切换中英文界面，设置开机自动启动 CCBar",
            keywords: ["language", "login", "startup", "语言", "中文", "english", "开机", "自启"]
        ),
        SettingsSearchItem(
            id: "general.diagnostics",
            category: .general,
            sectionID: "general-diagnostics",
            englishTitle: "Diagnostics & Verbose Logging",
            chineseTitle: "诊断日志与详细日志",
            englishSummary: "Export redacted diagnostic zip, open ~/Library/Logs/CCBar, toggle verbose log",
            chineseSummary: "导出脱敏 zip 诊断包、打开日志目录或开启详细日志",
            keywords: ["diagnostics", "log", "zip", "verbose", "诊断", "日志", "导出", "反馈"]
        ),
        SettingsSearchItem(
            id: "general.updates",
            category: .general,
            sectionID: "general-updates",
            englishTitle: "Updates & Version",
            chineseTitle: "软件更新与版本信息",
            englishSummary: "Check for updates, view version and configure automatic update checks",
            chineseSummary: "查看当前版本、手动检查更新或开关自动检查更新",
            keywords: ["update", "version", "about", "更新", "版本", "关于", "sparkle"]
        )
    ]
}

// MARK: - Layout & Metrics

enum SettingsLayout {
    /// 内容栏最大宽度，居中展示，留出呼吸空间并容纳分段控件与可见性按钮。
    static let contentMaxWidth: CGFloat = 720
    /// 卡片内行与卡片外分组标题共用的水平边距，保证标题与正文左沿对齐。
    static let cardHorizontalPadding: CGFloat = 18
    /// 各子页面模块卡片之间的纵向间距。
    static let sectionSpacing: CGFloat = 28
    /// 同卡内标准下拉框统一宽度（如刷新间隔）。
    static let menuPickerWidth: CGFloat = 116
    /// 紧凑数值下拉框统一宽度（如最近对话条数）。
    static let compactMenuPickerWidth: CGFloat = 84
    /// 语言下拉框宽度，保证中英双语选项不被截断。
    static let languagePickerWidth: CGFloat = 184
}

/// 服务行的缩进与右侧固定列宽。`ImportedCodexAccountsView` 的子行按同一套列对齐。
enum ServiceRowMetrics {
    static let leadingPadding: CGFloat = 16
    static let trailingPadding: CGFloat = 18
    /// 左侧重排抓手列。
    static let handleWidth: CGFloat = 16
    static let handleGap: CGFloat = 6
    static let tileSize: CGFloat = 32
    static let tileGap: CGFloat = 12
    /// 名称文字起点：内边距 + 手柄列 + 手柄间距 + tile + tile 间距。分隔线从这里开始。
    static let textLeading: CGFloat = leadingPadding + handleWidth + handleGap + tileSize + tileGap
    /// 菜单栏 / 悬浮窗单按钮固定宽度与间距，两列总宽精确等于 `destination * 2`。
    static let destinationItemWidth: CGFloat = 64
    static let destinationItemGap: CGFloat = 6
    static let destination: CGFloat = (destinationItemWidth * 2 + destinationItemGap) / 2
    static let info: CGFloat = 28
    static let toggle: CGFloat = 38
}

// MARK: - Bilingual display names for existing enums

extension QuotaIntervalChoice {
    @MainActor
    var bilingualDisplayName: String {
        switch self {
        case .m1: return tr("1 minute", "1 分钟")
        case .m2: return tr("2 minutes", "2 分钟")
        case .m3: return tr("3 minutes", "3 分钟")
        case .m5: return tr("5 minutes", "5 分钟")
        case .m10: return tr("10 minutes", "10 分钟")
        }
    }
}

extension ProxyMode {
    @MainActor
    var bilingualDisplayName: String {
        switch self {
        case .system: return tr("Follow System", "跟随系统")
        case .manual: return tr("Manual", "手动配置")
        }
    }
}

extension UsageIntervalChoice {
    @MainActor
    var bilingualDisplayName: String {
        switch self {
        case .m1: return tr("1 minute", "1 分钟")
        case .m2: return tr("2 minutes", "2 分钟")
        case .m3: return tr("3 minutes", "3 分钟")
        case .m5: return tr("5 minutes", "5 分钟")
        case .m10: return tr("10 minutes", "10 分钟")
        }
    }
}
