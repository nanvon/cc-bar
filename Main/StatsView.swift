import SwiftUI
import AppKit
import Charts

// MARK: - StatsRange

/// 时间范围。从属于 `StatsGranularity`：每个粒度只暴露自己那一组范围
/// （当前 / 上一个 / 近 N 个 / 全部 / 自定义），`.all` 与 `.custom` 三个粒度共用；
/// 日粒度额外保留 `.thisWeek` / `.thisMonth` / `.thisYear`，用于「按天看、但只统计本周 / 本月 / 本年」。
enum StatsRange: Hashable, CaseIterable {
    case today
    case yesterday
    case last7
    case last30
    case thisWeek
    case lastWeek
    case last4Weeks
    case last12Weeks
    case thisMonth
    case lastMonth
    case last6Months
    case thisYear
    case all
    case custom

    var englishLabel: String {
        switch self {
        case .today: return "Today"
        case .yesterday: return "Yesterday"
        case .last7: return "7d"
        case .last30: return "30d"
        case .thisWeek: return "This week"
        case .lastWeek: return "Last week"
        case .last4Weeks: return "4w"
        case .last12Weeks: return "12w"
        case .thisMonth: return "This month"
        case .lastMonth: return "Last month"
        case .last6Months: return "6m"
        case .thisYear: return "Year"
        case .all: return "All"
        case .custom: return "Custom"
        }
    }

    var chineseLabel: String {
        switch self {
        case .today: return "今天"
        case .yesterday: return "昨天"
        case .last7: return "7 天"
        case .last30: return "30 天"
        case .thisWeek: return "本周"
        case .lastWeek: return "上周"
        case .last4Weeks: return "4 周"
        case .last12Weeks: return "12 周"
        case .thisMonth: return "本月"
        case .lastMonth: return "上月"
        case .last6Months: return "6 个月"
        case .thisYear: return "本年"
        case .all: return "全部"
        case .custom: return "自定义"
        }
    }

    /// 周一为一周起点的公历；`StatsGranularity` 的周桶起点与 `weekRange` 文案共用同一份，
    /// 避免「本周」和周粒度出现两个周起点真相。
    static var weekStartMondayCalendar: Calendar {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = .current
        cal.firstWeekday = 2
        return cal
    }

    func bounds(now: Date = Date(), customFrom: Date, customTo: Date) -> (from: Date, to: Date) {
        let cal = Self.weekStartMondayCalendar
        let startOfToday = cal.startOfDay(for: now)
        let startOfTomorrow = cal.date(byAdding: .day, value: 1, to: startOfToday) ?? startOfToday

        switch self {
        case .today:
            return (startOfToday, startOfTomorrow)
        case .yesterday:
            let yesterdayStart = cal.date(byAdding: .day, value: -1, to: startOfToday) ?? startOfToday
            return (yesterdayStart, startOfToday)
        case .thisWeek:
            return (Self.weekStart(now, cal: cal, fallback: startOfToday), startOfTomorrow)
        case .lastWeek:
            let weekStart = Self.weekStart(now, cal: cal, fallback: startOfToday)
            let previous = cal.date(byAdding: .weekOfYear, value: -1, to: weekStart) ?? weekStart
            return (previous, weekStart)
        case .last4Weeks:
            let weekStart = Self.weekStart(now, cal: cal, fallback: startOfToday)
            let from = cal.date(byAdding: .weekOfYear, value: -3, to: weekStart) ?? weekStart
            return (from, startOfTomorrow)
        case .last12Weeks:
            let weekStart = Self.weekStart(now, cal: cal, fallback: startOfToday)
            let from = cal.date(byAdding: .weekOfYear, value: -11, to: weekStart) ?? weekStart
            return (from, startOfTomorrow)
        case .thisMonth:
            return (Self.monthStart(now, cal: cal, fallback: startOfToday), startOfTomorrow)
        case .lastMonth:
            let monthStart = Self.monthStart(now, cal: cal, fallback: startOfToday)
            let previous = cal.date(byAdding: .month, value: -1, to: monthStart) ?? monthStart
            return (previous, monthStart)
        case .last6Months:
            let monthStart = Self.monthStart(now, cal: cal, fallback: startOfToday)
            let from = cal.date(byAdding: .month, value: -5, to: monthStart) ?? monthStart
            return (from, startOfTomorrow)
        case .thisYear:
            let comps = cal.dateComponents([.year], from: now)
            let yearStart = cal.date(from: comps) ?? startOfToday
            return (yearStart, startOfTomorrow)
        case .last7:
            let from = cal.date(byAdding: .day, value: -6, to: startOfToday) ?? startOfToday
            return (from, startOfTomorrow)
        case .last30:
            let from = cal.date(byAdding: .day, value: -29, to: startOfToday) ?? startOfToday
            return (from, startOfTomorrow)
        case .all:
            return (.distantPast, .distantFuture)
        case .custom:
            let from = cal.startOfDay(for: customFrom)
            let toBase = cal.startOfDay(for: customTo)
            let to = cal.date(byAdding: .day, value: 1, to: toBase) ?? toBase
            return (from, max(from, to))
        }
    }

    private static func weekStart(_ date: Date, cal: Calendar, fallback: Date) -> Date {
        let comps = cal.dateComponents([.yearForWeekOfYear, .weekOfYear], from: date)
        return cal.date(from: comps) ?? fallback
    }

    private static func monthStart(_ date: Date, cal: Calendar, fallback: Date) -> Date {
        let comps = cal.dateComponents([.year, .month], from: date)
        return cal.date(from: comps) ?? fallback
    }

    /// delta 对比区间。`.all` / `.custom` 返回 nil(无法对比)。
    /// 本周 / 本月 / 本年是进行中的周期：对比上一周期从起点起的同样天数(周三的「本周」
    /// 对比上周一～周三)，不越过本周期起点；其余范围对比紧邻的上一个等长区间。
    func previousBounds(now: Date = Date(), customFrom: Date, customTo: Date) -> (from: Date, to: Date)? {
        let periodComponent: Calendar.Component?
        switch self {
        case .all, .custom:
            return nil
        case .thisWeek:
            periodComponent = .weekOfYear
        case .thisMonth:
            periodComponent = .month
        case .thisYear:
            periodComponent = .year
        default:
            periodComponent = nil
        }
        let current = bounds(now: now, customFrom: customFrom, customTo: customTo)
        if let periodComponent {
            let cal = Self.weekStartMondayCalendar
            guard let previousStart = cal.date(byAdding: periodComponent, value: -1, to: current.from),
                  let elapsedDays = cal.dateComponents([.day], from: current.from, to: current.to).day,
                  let previousEnd = cal.date(byAdding: .day, value: elapsedDays, to: previousStart)
            else { return nil }
            return (previousStart, min(previousEnd, current.from))
        }
        let length = current.to.timeIntervalSince(current.from)
        guard length > 0, length.isFinite else { return nil }
        return (current.from.addingTimeInterval(-length), current.from)
    }
}

// MARK: - StatsGranularity

/// 统计粒度，Overview / Conversations 的**上级**控件：它决定「一个统计单元」是一天、
/// 一周还是一个月，下级的 `StatsRange` 只能在该粒度自己那组范围里选。
/// 底层用量桶始终是日桶，周 / 月只在读取时把日桶归并到周期起点。
enum StatsGranularity: Hashable, CaseIterable {
    case day
    case week
    case month

    var englishLabel: String {
        switch self {
        case .day: return "Day"
        case .week: return "Week"
        case .month: return "Month"
        }
    }

    var chineseLabel: String {
        switch self {
        case .day: return "日"
        case .week: return "周"
        case .month: return "月"
        }
    }

    var panelTitleEnglish: String {
        switch self {
        case .day: return "Daily usage"
        case .week: return "Weekly usage"
        case .month: return "Monthly usage"
        }
    }

    var panelTitleChinese: String {
        switch self {
        case .day: return "每日用量"
        case .week: return "每周用量"
        case .month: return "每月用量"
        }
    }

    /// 该粒度下可选的时间范围：当前 / 上一个 / 近 N 个 / 全部 / 自定义。
    /// `.all` 与 `.custom` 三个粒度共用，切换粒度时不会被重置。
    /// 日粒度另外保留本周 / 本月 / 本年三档自然周期，按天分桶但只统计该周期。
    var ranges: [StatsRange] {
        switch self {
        case .day: return [.today, .yesterday, .last7, .last30, .thisWeek, .thisMonth, .thisYear, .all, .custom]
        case .week: return [.thisWeek, .lastWeek, .last4Weeks, .last12Weeks, .all, .custom]
        case .month: return [.thisMonth, .lastMonth, .last6Months, .thisYear, .all, .custom]
        }
    }

    /// 把日桶的本地 0 点日期归并到所属周期起点。周起点为周一，月起点为自然月 1 号；
    /// range 边界处的不完整周 / 月不补全，直接落进对应桶。
    func bucketStart(for day: Date) -> Date {
        let cal = StatsRange.weekStartMondayCalendar
        switch self {
        case .day:
            return day
        case .week:
            let comps = cal.dateComponents([.yearForWeekOfYear, .weekOfYear], from: day)
            return cal.date(from: comps) ?? day
        case .month:
            let comps = cal.dateComponents([.year, .month], from: day)
            return cal.date(from: comps) ?? day
        }
    }

    /// X 轴刻度文案：日 / 周显示月日(周为该周起始日),月显示年月。
    var axisDateFormat: Date.FormatStyle {
        switch self {
        case .day, .week:
            return Date.FormatStyle.dateTime.month(.abbreviated).day()
        case .month:
            return Date.FormatStyle.dateTime.year().month(.abbreviated)
        }
    }

    /// 单周期上下文窗口显示多少个周期（含所选那个）。日粒度取近 30 天，与「近 30 天」范围的柱数、柱宽一致；
    /// 周 / 月取 14 个，跨度约一个季度 / 一年多，再长的上下文对单周期对比意义不大。
    var contextWindowPeriods: Int {
        switch self {
        case .day: return 30
        case .week, .month: return 14
        }
    }

    /// 上下文窗口按该单位往前推：日 → 天，周 → 周，月 → 月。
    var contextWindowComponent: Calendar.Component {
        switch self {
        case .day: return .day
        case .week: return .weekOfYear
        case .month: return .month
        }
    }

    var contextWindowHintEnglish: String {
        switch self {
        case .day: return "Last 30 days · highlighted = selected"
        case .week: return "Last 14 weeks · highlighted = selected"
        case .month: return "Last 14 months · highlighted = selected"
        }
    }

    var contextWindowHintChinese: String {
        switch self {
        case .day: return "近 30 天 · 高亮为所选范围"
        case .week: return "近 14 周 · 高亮为所选范围"
        case .month: return "近 14 个月 · 高亮为所选范围"
        }
    }

    /// 悬浮明细的标题：日 `2026-09-03`,周 `2026-09-01 – 09-07`,月 `2026-09`。
    func periodLabel(_ start: Date) -> String {
        switch self {
        case .day: return StatsFormatter.day(start)
        case .week: return StatsFormatter.weekRange(start)
        case .month: return StatsFormatter.month(start)
        }
    }
}

// MARK: - Service filter (sidebar)

enum StatsServiceFilter: Hashable, CaseIterable {
    case all
    case codex
    case claude
    case cursor
    case pi
    case opencode
    case dsh

    var englishLabel: String {
        switch self {
        case .all: return "All"
        case .codex: return "Codex"
        case .claude: return "Claude Code"
        case .cursor: return "Cursor"
        case .pi: return "Pi"
        case .opencode: return "OpenCode"
        case .dsh: return "DSH"
        }
    }

    var chineseLabel: String {
        switch self {
        case .all: return "全部"
        case .codex: return "Codex"
        case .claude: return "Claude Code"
        case .cursor: return "Cursor"
        case .pi: return "Pi"
        case .opencode: return "OpenCode"
        case .dsh: return "DSH"
        }
    }

    var usageApp: UsageApp? {
        switch self {
        case .all: return nil
        case .codex: return .codex
        case .claude: return .claude
        case .cursor: return .cursor
        case .pi: return .pi
        case .opencode: return .opencode
        case .dsh: return .dsh
        }
    }
}

enum StatsViewMode: Hashable, CaseIterable {
    case overview
    case conversations
    case projects
    /// 额度：当前周期卡 + 额度变化时间线（原 Cycles 与 Timeline 合并）。
    case quota

    /// 顶栏页面标题，与侧栏视图项同名。
    @MainActor
    var title: String {
        switch self {
        case .overview: return tr("Overview", "概览")
        case .conversations: return tr("Conversations", "对话")
        case .projects: return tr("Projects", "项目")
        case .quota: return tr("Quota", "额度")
        }
    }
}

/// 统计页内的跨视图跳转请求（概览 → 对话 / 项目，项目 → 对话等）。
/// 目标视图出现或请求变化时消费并清空；`id` 保证重复点击同一目标也会生效。
struct StatsNavigationRequest: Equatable {
    enum Target: Equatable {
        case conversation(String)
        /// 对话页按排行口径（Tokens / 费用）排序。
        case conversationsByRank
        case conversationsInProject(String)
        case projectsList
        case project(String)
        case unattributed
    }

    let id = UUID()
    let target: Target
}

private struct CursorHistoryRequest: Hashable {
    let accountID: String
    let from: Date
    let to: Date

    var range: Range<Date> { from..<to }
}

// MARK: - StatsView

struct StatsView: View {
    @Environment(AppState.self) private var appState
    @State private var range: StatsRange = .today
    @State private var serviceFilter: StatsServiceFilter = .all
    @State private var viewMode: StatsViewMode = .overview
    @State private var customFrom: Date = Calendar.current.startOfDay(
        for: Date().addingTimeInterval(-7 * 86400)
    )
    @State private var customTo: Date = Calendar.current.startOfDay(for: Date())
    @State private var granularity: StatsGranularity = .day
    /// 概览派生结果的同步缓存，见 `StatsOverviewCache`。
    @State private var overviewCache = StatsOverviewCache()
    /// 时间线窗口视角全局统一，避免 Codex 与 Claude 默认落在不同口径。
    @State private var timelineWindow: QuotaLimitKind = .fiveHour
    @State private var pendingNavigation: StatsNavigationRequest?
    /// 概览 / 额度页的滚动画布是否已离开顶部，决定顶栏分隔线是否显示（见 `showsTopBarDivider`）。
    @State private var canvasScrolled = false
    /// 一屏高度分配的实测值（规则见 `overviewBottomRowMinHeight`）：概览 KPI 行、概览下排。
    @State private var overviewTopHeight: CGFloat = 0
    @State private var overviewBottomHeight: CGFloat = 0

    var body: some View {
        HStack(spacing: 0) {
            sidebar
                .frame(width: MainWindowLayout.sidebarWidth)

            // 与侧栏材质一起延伸进标题栏，侧栏右边界从上到下是同一条线。
            Divider()
                .ignoresSafeArea(.container, edges: .top)

            VStack(spacing: 0) {
                StatsUsageErrorBanner()

                // 顶栏由四个视图共用、放在页面内容之外：切换视图时是同一个视图，
                // 粒度 / 范围控件和日期选择器的位置不跳、不重建；也不随概览 / 额度页滚动。
                topBar
                // 始终占位、只切透明度：出现 / 消失时下方内容不上下移 1pt。
                Divider()
                    .opacity(showsTopBarDivider ? 1 : 0)
                    .animation(.easeOut(duration: 0.15), value: showsTopBarDivider)

                switch viewMode {
                case .conversations:
                    ConversationStatsView(
                        granularity: $granularity,
                        range: $range,
                        customFrom: $customFrom,
                        customTo: $customTo,
                        serviceFilter: serviceFilter,
                        navigation: $pendingNavigation
                    )
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                case .projects:
                    ProjectStatsView(
                        granularity: $granularity,
                        range: $range,
                        customFrom: $customFrom,
                        customTo: $customTo,
                        serviceFilter: serviceFilter,
                        navigation: $pendingNavigation,
                        navigate: navigate,
                        showServiceInOverview: { app in
                            serviceFilter = filter(for: app)
                            viewMode = .overview
                        }
                    )
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                case .overview, .quota:
                    GeometryReader { proxy in
                        ScrollView {
                            mainContent(canvasWidth: proxy.size.width, canvasHeight: proxy.size.height)
                        }
                        .onScrolledPastTop { canvasScrolled = $0 }
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        }
        .onAppear { reconcileServiceFilter() }
        .onChange(of: SettingsStore.shared.usageServiceVisibility) { _, _ in
            reconcileServiceFilter()
        }
        .onChange(of: viewMode) { _, mode in
            reconcileServiceFilter()
            // 离开滚动画布后清掉滚动状态，回到概览 / 额度时新画布从顶部开始。
            if mode == .projects || mode == .conversations { canvasScrolled = false }
        }
        .onChange(of: granularity) { _, _ in reconcileRange() }
        .task(id: cursorHistoryRequest) {
            guard let request = cursorHistoryRequest else { return }
            await appState.loadCursorUsageHistory(for: request.range)
        }
    }

    /// 顶栏分隔线：对话 / 项目页下方是贴边的左右分栏，一直显示，与分栏竖线相接；
    /// 概览 / 额度页是卡片，静止时只靠间距与顶栏分开，内容滚到顶栏下方后才显示。
    private var showsTopBarDivider: Bool {
        switch viewMode {
        case .conversations, .projects: return true
        case .overview, .quota: return canvasScrolled
        }
    }

    /// 宽度断点:主画布达到该宽度时,概览与额度页的面板左右并排;
    /// 更窄(如最小窗口)时回落单列堆叠,避免内容挤压截断。
    static let wideCanvasWidth: CGFloat = 880

    /// 默认窗口 1440×900 下的一屏高度分配：概览下排（用量构成 + 高消耗对话）至少 390pt，
    /// 用量柱状图那一排吃掉剩余高度、260~300pt。
    /// 用量构成列表区固定高度、内部滚动，不会撑高下排。
    static let overviewBottomRowMinHeight: CGFloat = 390
    static let overviewUsageRowMinHeight: CGFloat = 260
    /// 柱状图那一排的上限：窗口比默认高很多时不再继续拉高，多出的高度留在页面底部，
    /// 避免图表和 Token 拆分被拉成细长比例、面板内部出现大块空白。
    static let overviewUsageRowMaxHeight: CGFloat = 300
    /// 额度页折线图固定高度：不随画布拉伸，展开变动明细时面板向下变长、整页滚动，不压缩图表。
    static let quotaTimelineChartHeight: CGFloat = 200

    @ViewBuilder
    private func mainContent(canvasWidth: CGFloat, canvasHeight: CGFloat) -> some View {
        let isWide = canvasWidth >= Self.wideCanvasWidth
        switch viewMode {
        case .overview:
            overviewContent(canvasWidth: canvasWidth, canvasHeight: canvasHeight, isWide: isWide)
        case .quota:
            quotaContent(isWide: isWide)
        case .conversations, .projects:
            EmptyView()
        }
    }

    private func overviewContent(canvasWidth: CGFloat, canvasHeight: CGFloat, isWide: Bool) -> some View {
        let model = overviewModel
        let scope = StatsOverviewScope(range: range, granularity: granularity, serviceFilter: serviceFilter)
        let contentWidth = max(0, canvasWidth - 40)
        return VStack(alignment: .leading, spacing: 12) {
            OverviewKPIRow(model: model, serviceFilter: serviceFilter)
                .onHeightChange { overviewTopHeight = $0 }

            StatsSplitRow(
                isWide: isWide,
                width: contentWidth,
                leadingFraction: 2.0 / 3.0,
                minHeight: isWide ? overviewUsageRowHeight(canvasHeight: canvasHeight) : nil
            ) {
                OverviewUsageChartPanel(model: model, granularity: granularity, scope: scope)
            } trailing: {
                OverviewTokenBreakdownPanel(model: model)
            }

            StatsSplitRow(
                isWide: isWide,
                width: contentWidth,
                leadingFraction: 5.0 / 9.0,
                minHeight: isWide ? Self.overviewBottomRowMinHeight : nil
            ) {
                OverviewCompositionPanel(
                    model: model,
                    scope: scope,
                    onSelectService: { app in serviceFilter = filter(for: app) },
                    navigate: navigate
                )
            } trailing: {
                OverviewTopConversationsPanel(model: model, navigate: navigate)
            }
            .onHeightChange { overviewBottomHeight = $0 }
        }
        // 顶部不留白:与顶栏的间距由顶栏下边距给出(见 topBar)。
        .padding([.horizontal, .bottom], 20)
    }

    /// 柱状图那一排 = 画布高 − 底部内边距 − KPI 行 − 下排 − 两个行间距，夹在上下限之间。
    /// KPI 行与下排尚未测出时先按下限排，避免首帧撑出超高的一排。
    private func overviewUsageRowHeight(canvasHeight: CGFloat) -> CGFloat {
        guard overviewTopHeight > 0, overviewBottomHeight > 0 else { return Self.overviewUsageRowMinHeight }
        let remaining = canvasHeight - 20 - overviewTopHeight - overviewBottomHeight - 12 * 2
        return min(Self.overviewUsageRowMaxHeight, max(Self.overviewUsageRowMinHeight, remaining.rounded(.down)))
    }

    private func navigate(_ target: StatsNavigationRequest.Target) {
        pendingNavigation = StatsNavigationRequest(target: target)
        switch target {
        case .conversation, .conversationsByRank, .conversationsInProject:
            viewMode = .conversations
        case .projectsList, .project, .unattributed:
            viewMode = .projects
        }
    }

    // MARK: Quota

    /// 额度页随侧栏服务筛选：全部 → Codex + Claude；单选 Codex / Claude 只看该服务；
    /// 其他服务没有额度周期与额度历史，整页显示空态。
    private var quotaApps: [UsageApp] {
        switch serviceFilter {
        case .all: return [.codex, .claude]
        case .codex: return [.codex]
        case .claude: return [.claude]
        case .cursor, .pi, .opencode, .dsh: return []
        }
    }

    private func quotaContent(isWide: Bool) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            if quotaApps.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "gauge.with.needle")
                        .font(.system(size: 24))
                        .foregroundStyle(.tertiary)
                    Text(tr("No quota data", "暂无额度数据"))
                        .font(.system(size: 13, weight: .medium))
                    Text(tr(
                        "Only Codex and Claude Code report quota cycles.",
                        "只有 Codex 与 Claude Code 提供额度周期。"
                    ))
                    .font(.system(size: 11.5))
                    .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity)
                .frame(height: 220)
                .ccPanel(cornerRadius: 12)
            } else {
                QuotaCycleCardsSection(apps: quotaApps, isWide: isWide)
                quotaTimelineSection(isWide: isWide)
            }
        }
        .padding([.horizontal, .bottom], 20)
    }

    private func quotaTimelineSection(isWide: Bool) -> some View {
        let sections = timelineSections
        let columns = isWide ? 2 : 1
        return VStack(alignment: .leading, spacing: 12) {
            timelineHeader
            if sections.isEmpty {
                placeholderHeight(220, message: tr("No accounts", "暂无账号"))
                    .ccPanel(cornerRadius: 12)
            } else {
                LazyVGrid(
                    columns: Array(
                        repeating: GridItem(.flexible(), spacing: 12, alignment: .top),
                        count: columns
                    ),
                    alignment: .leading,
                    spacing: 12
                ) {
                    ForEach(sections) { section in
                        QuotaTimelineAccountPanel(
                            section: section,
                            selectedKind: timelineWindow,
                            chartHeight: Self.quotaTimelineChartHeight
                        )
                    }
                }
            }
        }
    }

    // MARK: Sidebar

    private var visibleUsageApps: [UsageApp] {
        SettingsStore.shared.visibleUsageApps
    }

    private var visibleServiceFilters: [StatsServiceFilter] {
        [.all] + visibleUsageApps.map { filter(for: $0) }
    }

    private func filter(for app: UsageApp) -> StatsServiceFilter {
        switch app {
        case .codex: return .codex
        case .claude: return .claude
        case .cursor: return .cursor
        case .pi: return .pi
        case .opencode: return .opencode
        case .dsh: return .dsh
        }
    }

    /// 设置里被关闭的服务,其 sidebar 项不再显示;若当前选中了被关闭的服务则回退到全部。
    private func reconcileServiceFilter() {
        // Cursor Dashboard 没有本机会话 ID；对话页不能伪造或查询 Cursor 对话，项目页也无法归属。
        if viewMode == .conversations || viewMode == .projects, serviceFilter == .cursor {
            serviceFilter = .all
            return
        }
        if case .all = serviceFilter { return }
        if let app = serviceFilter.usageApp, !SettingsStore.shared.isUsageServiceEffectivelyVisible(app) {
            serviceFilter = .all
        }
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 16) {
            sidebarGroup(title: "Service", chinese: "服务") {
                ForEach(visibleServiceFilters, id: \.self) { item in
                    sidebarItem(
                        english: item.englishLabel,
                        chinese: item.chineseLabel,
                        app: item.usageApp,
                        active: serviceFilter == item
                    ) {
                        serviceFilter = item
                        // 项目 / 对话视图下选 Cursor 立即回退，规则见 reconcileServiceFilter。
                        reconcileServiceFilter()
                    }
                }
            }

            sidebarGroup(title: "View", chinese: "视图") {
                sidebarItem(
                    english: "Overview",
                    chinese: "概览",
                    icon: "rectangle.split.2x2",
                    active: viewMode == .overview
                ) {
                    viewMode = .overview
                }
                sidebarItem(
                    english: "Conversations",
                    chinese: "对话",
                    icon: "bubble.left.and.bubble.right",
                    active: viewMode == .conversations
                ) {
                    viewMode = .conversations
                }
                sidebarItem(
                    english: "Projects",
                    chinese: "项目",
                    icon: "folder",
                    active: viewMode == .projects
                ) {
                    viewMode = .projects
                }
                sidebarItem(
                    english: "Quota",
                    chinese: "额度",
                    icon: "gauge.with.needle",
                    active: viewMode == .quota
                ) {
                    viewMode = .quota
                }
            }

            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 14)
        .frame(maxHeight: .infinity, alignment: .top)
        .background(.regularMaterial)
    }

    @ViewBuilder
    private func sidebarGroup<Content: View>(
        title: String,
        chinese: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(tr(title, chinese).uppercased())
                .font(.system(size: 10, weight: .semibold))
                .kerning(0.4)
                .foregroundStyle(.tertiary)
                .padding(.horizontal, 6)
                .padding(.bottom, 4)
            content()
        }
    }

    private func sidebarItem(
        english: String,
        chinese: String,
        app: UsageApp? = nil,
        icon: String? = nil,
        active: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 8) {
                if let icon {
                    Image(systemName: icon)
                        .font(.system(size: 12))
                        .frame(width: 14, height: 14)
                        .foregroundStyle(active ? Color.white : Color.secondary)
                } else if let app {
                    ServiceTile(app: app, size: 14)
                } else {
                    Color.clear.frame(width: 14, height: 14)
                }

                Text(tr(english, chinese))
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(active ? Color.white : Color.primary)

                Spacer()
            }
            .padding(.vertical, 5)
            .padding(.horizontal, 8)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(active ? Color.accentColor : Color.clear)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .focusEffectDisabled()
        .pointingHandCursor()
    }

    // MARK: Top bar (segmented + custom)

    /// 四个视图共用的顶栏：标题 + 各视图的说明 / 扫描状态，右侧粒度、范围控件（额度页没有）。
    private var topBar: some View {
        StatsTopBar(
            mode: viewMode,
            granularity: $granularity,
            range: $range,
            customFrom: $customFrom,
            customTo: $customTo
        ) {
            topBarDetail
        }
        .padding(.horizontal, 20)
        // 上下同为 14:概览 / 额度页不画分隔线时,顶栏到卡片的间距就是下边距 14(画布顶部不再留白),
        // 与上方间距相等;14 大于卡片间距 12,顶栏仍自成一组。
        .padding(.vertical, 14)
    }

    /// 标题右侧的内容。扫描提示会自行出现 / 消失，放在左侧剩余空间里靠右，
    /// 不挤占右侧控件，也不会把控件推着平移。
    @ViewBuilder
    private var topBarDetail: some View {
        switch viewMode {
        case .overview:
            Text(overviewScopeCaption)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .monospacedDigit()
                .lineLimit(1)
            StatsScanningIndicator()
                .frame(maxWidth: .infinity, alignment: .trailing)
        case .quota:
            EmptyView()
        case .projects:
            if appState.usageService.isScanning, !appState.usageService.conversationAggregator.isEmpty {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text(tr("Scanning…", "正在扫描…"))
                        .font(.system(size: 11.5))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
        case .conversations:
            ConversationScanStatus(
                isScanning: appState.usageService.isScanning,
                isEmpty: appState.usageService.conversationAggregator.isEmpty,
                lastScanAt: appState.usageService.lastScanAt
            )
            .font(.system(size: 11.5))
            .monospacedDigit()
            .lineLimit(1)

            Button {
                Task { await appState.usageService.scanNow() }
            } label: {
                if appState.usageService.isScanning {
                    ProgressView().controlSize(.small)
                } else {
                    Image(systemName: "arrow.clockwise")
                }
            }
            .buttonStyle(.borderless)
            .frame(width: 26, height: 22)
            .help(tr("Refresh local usage", "刷新本地用量"))
        }
    }

    /// 标题旁的口径说明：`全部服务 · 2026-08-30 至 09-28`。
    private var overviewScopeCaption: String {
        let service = serviceFilter == .all
            ? tr("All services", "全部服务")
            : tr(serviceFilter.englishLabel, serviceFilter.chineseLabel)
        let period: String
        if range == .all {
            period = tr("All time", "全部时间")
        } else {
            let (from, to) = rangeBounds
            period = StatsFormatter.dayRange(from: from, toExclusive: to)
        }
        return "\(service) · \(period)"
    }

    /// 切换粒度后，把不属于新粒度的范围收敛到该粒度的第一档；
    /// `.all` / `.custom` 在三个粒度里都在，切换时会原样保留。
    private func reconcileRange() {
        guard !granularity.ranges.contains(range) else { return }
        range = granularity.ranges.first ?? .all
    }

    // MARK: Timeline

    private var timelineHeader: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(timelineWindow == .weekly
                 ? tr("Weekly quota changes", "周额度变化")
                 : tr("Quota changes today", "今天的额度变化"))
                .font(.system(size: 13, weight: .semibold))
            Spacer()
            Picker(tr("Quota window", "额度窗口"), selection: $timelineWindow) {
                ForEach(QuotaTimelineWindowKind.pickable, id: \.self) { item in
                    Text(item.label).tag(item.kind)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 128)
            Text(StatsFormatter.day(Date()))
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(.secondary)
        }
    }

    private var timelineSections: [QuotaTimelineSection] {
        let apps = Set(quotaApps)
        var sections: [QuotaTimelineSection] = []

        if apps.contains(.codex) {
            let key = QuotaHistoryAccountKey.codexPrimary(accountId: appState.codexAccount?.accountId)
            var addedPrimaryCodex = false
            if shouldShowTimelineSection(accountKey: key, snapshot: appState.codexQuota, accountExists: appState.codexAccount != nil) {
                sections.append(timelineSection(
                    accountKey: key,
                    title: "Codex",
                    app: .codex,
                    snapshot: appState.codexQuota,
                    isLoading: appState.refreshState(for: .codex).inFlight
                ))
                addedPrimaryCodex = true
            }

            for account in appState.importedCodexAccounts {
                // 展示层去重:主账号段已展示时,跳过与它同身份的镜像导入项(历史 key 不变,仍在盘上)。
                if addedPrimaryCodex && appState.importedCodexAccountMirrorsPrimary(account) { continue }
                let key = QuotaHistoryAccountKey.codexImported(id: account.id)
                sections.append(timelineSection(
                    accountKey: key,
                    title: importedCodexTimelineTitle(account),
                    app: .codex,
                    snapshot: appState.importedCodexQuota(for: account),
                    isLoading: appState.importedCodexRefreshState(for: account).inFlight
                ))
            }
        }

        if apps.contains(.claude) {
            let key = QuotaHistoryAccountKey.claudePrimary(email: appState.claudeAccount?.email)
            if shouldShowTimelineSection(accountKey: key, snapshot: appState.claudeQuota, accountExists: appState.claudeAccount != nil) {
                sections.append(timelineSection(
                    accountKey: key,
                    title: "Claude Code",
                    app: .claude,
                    snapshot: appState.claudeQuota,
                    isLoading: appState.refreshState(for: .claude).inFlight
                ))
            }
        }

        return sections
    }

    private func timelineSection(
        accountKey: String,
        title: String,
        app: UsageApp,
        snapshot: QuotaSnapshot?,
        isLoading: Bool
    ) -> QuotaTimelineSection {
        let windows: [QuotaTimelineWindow] = [.fiveHour, .weekly].compactMap { kind in
            timelineWindowSection(accountKey: accountKey, kind: kind, snapshot: snapshot)
        }
        return QuotaTimelineSection(
            accountKey: accountKey,
            title: title,
            app: app,
            windows: windows,
            isLoading: isLoading
        )
    }

    /// 每个标准窗口（5H / 每周）在「快照当前持有该窗口」或「历史留有该系列数据」时展示。
    private func timelineWindowSection(
        accountKey: String,
        kind: QuotaLimitKind,
        snapshot: QuotaSnapshot?
    ) -> QuotaTimelineWindow? {
        let events = timelineEvents(for: accountKey, kind: kind)
        let sample = appState.quotaHistory.lastSamples[
            QuotaHistoryStore.seriesKey(accountKey: accountKey, limitKind: kind)
        ]
        let snapshotWindow = window(of: kind, in: snapshot)
        guard sample != nil || !events.isEmpty || snapshotWindow != nil else { return nil }

        return QuotaTimelineWindow(
            kind: kind,
            currentRemaining: sample?.remainingPercent ?? roundedRemaining(snapshotWindow),
            latestSampleAt: sample?.sampledAt,
            resetsAt: snapshotWindow?.resetsAt,
            periods: QuotaHistoryStore.timelinePeriods(
                payload: appState.quotaHistory,
                accountKey: accountKey,
                limitKind: kind
            )
        )
    }

    private func roundedRemaining(_ window: QuotaWindow?) -> Int? {
        guard let remaining = window?.remainingPercent else { return nil }
        return max(0, min(100, Int(remaining.rounded())))
    }

    private func window(of kind: QuotaLimitKind, in snapshot: QuotaSnapshot?) -> QuotaWindow? {
        guard let snapshot else { return nil }
        switch kind {
        case .fiveHour: return snapshot.fiveHourLimit?.window
        case .weekly: return snapshot.weeklyLimit?.window
        case .modelWeekly, .unknown: return nil
        }
    }

    private func shouldShowTimelineSection(accountKey: String, snapshot: QuotaSnapshot?, accountExists: Bool) -> Bool {
        let history = appState.quotaHistory
        let hasSeries = history.lastSamples.keys.contains {
            $0.hasPrefix("\(accountKey)|")
        }
        return accountExists || snapshot != nil || hasSeries
            || history.events.contains { $0.accountKey == accountKey }
    }

    private func timelineEvents(for accountKey: String, kind: QuotaLimitKind) -> [QuotaChangeEvent] {
        appState.quotaHistory.events
            .filter { $0.accountKey == accountKey && $0.limitKind == kind }
            .sorted { $0.sampledAt < $1.sampledAt }
    }

    private func importedCodexTimelineTitle(_ account: ImportedCodexAccount) -> String {
        if SettingsStore.shared.privacyMode {
            return "Codex · \(PrivacyDisplay.account(account.id))"
        }
        if !account.alias.isEmpty { return "Codex · \(account.alias)" }
        if let email = account.email, !email.isEmpty {
            return "Codex · \(email.components(separatedBy: "@").first ?? email)"
        }
        return "Codex · \(account.id)"
    }

    // MARK: Data helpers

    private var rangeBounds: (from: Date, to: Date) {
        range.bounds(customFrom: customFrom, customTo: customTo)
    }

    private var previousRangeBounds: (from: Date, to: Date)? {
        range.previousBounds(customFrom: customFrom, customTo: customTo)
    }

    /// 所选范围只落在**一个当前粒度周期**内(日:今天 / 昨天 / 单日自定义;周:本周 / 上周;
    /// 月:本月 / 上月;以及不跨周期的自定义)时,用量图表扩展为近若干周期的上下文(日 30、周 / 月 14),
    /// 范围内柱子高亮、范围外降透明;KPI 与其他面板口径不变。
    private var chartUsesContextWindow: Bool {
        guard range != .all else { return false }
        let (from, to) = rangeBounds
        guard to > from else { return false }
        // 按桶归属判断而非按时长,夏令时的 23/25 小时和月份天数差都不会影响结果。
        return selectedPeriodStart == granularity.bucketStart(for: lastDayInRange)
    }

    /// 所选范围首日所属的周期起点——上下文窗口里唯一全彩的那根柱子。
    private var selectedPeriodStart: Date {
        let cal = StatsRange.weekStartMondayCalendar
        return granularity.bucketStart(for: cal.startOfDay(for: rangeBounds.from))
    }

    /// 所选范围末日(右开区间往回退一秒再取当天 0 点)。
    private var lastDayInRange: Date {
        let cal = StatsRange.weekStartMondayCalendar
        return cal.startOfDay(for: rangeBounds.to.addingTimeInterval(-1))
    }

    /// 图表展示窗口:上下文模式取「所选周期起点往前 N−1 个周期」,连所选那个共 N 个(`contextWindowPeriods`)。
    /// 从周期起点往前推而不是从范围结束时刻往前推,首柱才是完整的周 / 月,不会天然偏矮。
    private var chartBounds: (from: Date, to: Date) {
        let bounds = rangeBounds
        guard chartUsesContextWindow else { return bounds }
        let cal = StatsRange.weekStartMondayCalendar
        let from = cal.date(byAdding: granularity.contextWindowComponent,
                            value: -(granularity.contextWindowPeriods - 1),
                            to: selectedPeriodStart) ?? bounds.from
        return (min(from, bounds.from), bounds.to)
    }

    /// 概览全部面板共用的派生结果。输入（日聚合与对话聚合的 revision、范围、粒度、服务过滤、
    /// 可见服务）不变时直接复用缓存，悬停、展开、切换构成维度、扫描提示等刷新都不会重新聚合。
    private var overviewModel: StatsOverviewModel {
        let aggregator = appState.usageService.aggregator
        let conversations = appState.usageService.conversationAggregator
        let current = rangeBounds
        let chart = chartBounds
        let serviceApp = serviceFilter.usageApp
        let metric = SettingsStore.shared.statsRankMetric
        let input = StatsOverviewInput(
            revision: aggregator.revision,
            current: StatsDateInterval(from: current.from, to: current.to),
            previous: previousRangeBounds.map { StatsDateInterval(from: $0.from, to: $0.to) },
            chart: StatsDateInterval(from: chart.from, to: chart.to),
            granularity: granularity,
            serviceApp: serviceApp,
            visibleApps: visibleUsageApps,
            highlightedPeriodStart: chartUsesContextWindow ? selectedPeriodStart : nil,
            conversationRevision: conversations.revision,
            rankMetric: metric
        )
        let apps = Set(visibleUsageApps.filter { serviceApp == nil || $0 == serviceApp })
        return overviewCache.model(
            for: input,
            buckets: { aggregator.snapshot() },
            conversationOverview: {
                conversations.overviewBreakdown(ConversationOverviewRequest(
                    revision: conversations.revision,
                    from: current.from,
                    to: current.to,
                    apps: apps,
                    topConversationLimit: 5,
                    metric: metric
                ))
            }
        )
    }

    private var cursorUsageIsInCurrentScope: Bool {
        SettingsStore.shared.isUsageServiceEffectivelyVisible(.cursor)
            && (serviceFilter == .all || serviceFilter == .cursor)
    }

    /// 当前范围外的历史由 Stats 选择时按月静默补拉；All 没有可靠的远端起点，
    /// 所以只使用现有缓存，绝不偷偷发起无界回溯。项目页的「未归属」也包含 Cursor，同样补拉。
    /// 起点同时覆盖上一周期与图表上下文窗口，避免上下文柱里的 Cursor 用量因未补拉而显示为空。
    private var cursorHistoryRequest: CursorHistoryRequest? {
        guard viewMode == .overview || viewMode == .projects,
              cursorUsageIsInCurrentScope,
              range != .all,
              let accountID = appState.cursorAccount?.userID
        else { return nil }

        let current = rangeBounds
        let from = min(previousRangeBounds?.from ?? current.from, chartBounds.from)
        let requested = from..<current.to
        guard !appState.usageService.isCursorRemoteUsageCovered(requested) else { return nil }
        return CursorHistoryRequest(accountID: accountID, from: requested.lowerBound, to: requested.upperBound)
    }
}

/// 概览、项目页并排的两块：宽画布按比例左右排，窄画布上下排。两块等高。
/// `minHeight` 只在宽画布生效：整排至少这么高（内容更高时照常撑开），面板里的弹性区块（如柱状图）随之变高。
struct StatsSplitRow<Leading: View, Trailing: View>: View {
    let isWide: Bool
    let width: CGFloat
    let leadingFraction: CGFloat
    var minHeight: CGFloat? = nil
    @ViewBuilder var leading: () -> Leading
    @ViewBuilder var trailing: () -> Trailing

    private let spacing: CGFloat = 12

    var body: some View {
        if isWide {
            HStack(alignment: .top, spacing: spacing) {
                leading()
                    .frame(width: max(0, ((width - spacing) * leadingFraction).rounded(.down)))
                    .frame(minHeight: minHeight, maxHeight: .infinity, alignment: .top)
                trailing()
                    .frame(maxWidth: .infinity, minHeight: minHeight, maxHeight: .infinity, alignment: .top)
            }
            .fixedSize(horizontal: false, vertical: true)
        } else {
            VStack(alignment: .leading, spacing: spacing) {
                leading()
                trailing()
            }
        }
    }
}

extension View {
    /// 报告自身布局高度（出现时与每次变化时），用于统计页按画布高度分配一屏空间。
    func onHeightChange(_ action: @escaping (CGFloat) -> Void) -> some View {
        background(
            GeometryReader { proxy in
                Color.clear
                    .onAppear { action(proxy.size.height) }
                    .onChange(of: proxy.size.height) { _, height in action(height) }
            }
        )
    }
}

// MARK: - Overview panels
//
// 概览各面板拆成独立视图，只接收 `StatsOverviewModel` 这类已派生好的值：
// 面板内部不再过滤聚合日桶；悬停、展开等局部状态放在各自面板里，
// 变化时只重绘该面板，不会让整页重新求值。

/// 面板局部状态（图表悬停、提供商展开）的重置时机：范围 / 粒度 / 服务过滤任一变化。
private struct StatsOverviewScope: Hashable {
    let range: StatsRange
    let granularity: StatsGranularity
    let serviceFilter: StatsServiceFilter
}

/// 本地日志读取或聚合持久化失败时必须在统计页可见，并给出直接恢复入口。
/// 具体技术错误保留在 hover help，主文案只说明数据状态与安全行为。
/// 单独成视图：只有它读 `lastError`，扫描结束写回该字段时不会连带整页重新求值。
private struct StatsUsageErrorBanner: View {
    @Environment(AppState.self) private var appState

    private func historyMessage(notice: UsageHistoryRecoveryNotice?, hasError: Bool) -> String {
        if notice?.isUnavailable == true {
            return tr(
                "Local usage history could not be loaded, so new usage is paused. Files are untouched; restore a backup and restart CCBar.",
                "无法读取本地用量历史，已暂停统计新用量。原文件未改动，恢复备份后重启 CCBar。"
            )
        }
        if notice?.isReadOnly == true {
            return tr(
                "Usage history was saved by a newer CCBar. New usage is paused and only a compatible backup (if any) is shown. Update CCBar to continue.",
                "用量历史由更新版本的 CCBar 保存，已暂停统计新用量，仅显示兼容的备份（如有）。请更新 CCBar。"
            )
        }
        if notice?.isRestricted == true {
            return notice?.verificationRejected == true
                ? tr("History verification failed. Existing data kept; new usage is paused. Restore the logs or fix disk read/write errors, then retry.",
                     "历史校验未通过。现有数据保留，已暂停统计新用量。恢复日志或解决磁盘读写问题后再试。")
                : tr("Existing data kept. New usage is paused until history is verified.",
                     "现有数据保留。历史校验通过前，暂停统计新用量。")
        }
        if notice?.isDshFrozen == true {
            return tr("DSH session details are unavailable, so DSH usage is paused. Existing data kept; other services are not affected.",
                      "DSH 会话明细不可用，已暂停统计 DSH。现有数据保留，其他服务不受影响。")
        }
        return hasError
            ? tr("Usage statistics may be incomplete. Existing data kept; retry later or recalculate in Settings.",
                 "用量统计可能不完整。现有数据保留，可稍后重试或到设置中重新计算。")
            : tr("Usage history was restored from the last complete save. Logs deleted after that cannot be recovered.",
                 "用量历史已恢复到最近一次完整保存，之后被删除的日志无法找回。")
    }

    var body: some View {
        let error = appState.usageService.lastError
        let notice = appState.usageService.historyRecoveryNotice
        if error != nil || notice != nil {
            HStack(spacing: 8) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 11))
                VStack(alignment: .leading, spacing: 2) {
                    Text(historyMessage(notice: notice, hasError: error != nil))
                    .font(.system(size: 11.5))
                    .fixedSize(horizontal: false, vertical: true)
                    if let notice, let restoredAt = notice.restoredFromPreviousAt {
                        Text(tr(
                            "Saved at \(restoredAt.formatted(date: .abbreviated, time: .shortened)).",
                            "保存时间：\(restoredAt.formatted(date: .abbreviated, time: .shortened))"
                        ))
                        .font(.system(size: 11))
                        .lineLimit(1)
                    }
                }
                Spacer(minLength: 8)
                if error != nil, notice?.isReadOnly != true, notice?.isDshFrozen != true {
                    Button(tr("Open Settings", "打开设置")) {
                        appState.mainTab = .settings
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }
            }
            .foregroundStyle(.orange)
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.orange.opacity(0.08))
            .overlay(alignment: .bottom) { Divider() }
            .help(PrivacyDisplay.help(error ?? ""))
        }
    }
}

/// 顶栏的后台扫描提示。单独成视图：每轮扫描 `isScanning` 翻转两次，只重绘这一小块。
private struct StatsScanningIndicator: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        HStack(spacing: 6) {
            if appState.usageService.isScanning {
                ProgressView()
                    .controlSize(.small)
                Text(tr("Recalculating usage…", "正在重新计算用量…"))
                    .font(.system(size: 11.5))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
    }
}

// MARK: KPI row

private struct OverviewKPIRow: View {
    let model: StatsOverviewModel
    let serviceFilter: StatsServiceFilter

    var body: some View {
        HStack(spacing: 12) {
            KPICard(
                english: "Total tokens",
                chinese: "总 Tokens",
                value: StatsFormatter.compactToken(model.totalsAll.totalTokens),
                delta: deltaPercent(current: Double(model.totalsAll.totalTokens),
                                    previous: Double(model.previousTotalsAll.totalTokens)),
                app: nil,
                dimmed: false
            )
            KPICard(
                english: "Cost",
                chinese: "费用",
                value: StatsFormatter.tierCost(
                    model.totalsAll.costUSD,
                    hasUnpricedUsage: model.totalsAll.hasUnpricedUsage,
                    costIncomplete: model.totalsAll.costIncomplete
                ),
                delta: costDelta(current: model.totalsAll, previous: model.previousTotalsAll),
                app: nil,
                dimmed: false
            )
            ForEach(model.visibleApps, id: \.self) { app in
                serviceCard(for: app)
            }
        }
    }

    private func serviceCard(for app: UsageApp) -> some View {
        let isDimmed = serviceFilter.usageApp != nil && serviceFilter.usageApp != app
        let totals = model.totals(app)
        return KPICard(
            english: app.displayName,
            chinese: app.displayName,
            value: isDimmed
                ? "—"
                : StatsFormatter.tierCost(
                    totals.costUSD,
                    hasUnpricedUsage: totals.hasUnpricedUsage,
                    costIncomplete: totals.costIncomplete
                ),
            delta: isDimmed ? nil : costDelta(current: totals, previous: model.previousTotals(app)),
            app: app,
            dimmed: isDimmed
        )
    }

    private func deltaPercent(current: Double, previous: Double) -> Double? {
        guard model.hasPreviousRange else { return nil }
        guard previous > 0 else { return nil }
        // 当前值为 0 时固定是 ↓100%,对没有用量的服务没有信息量,直接不渲染。
        guard current > 0 else { return nil }
        return ((current - previous) / previous) * 100
    }

    private func costDelta(current: UsageTotals, previous: UsageTotals) -> Double? {
        return deltaPercent(current: current.costUSD.doubleValue, previous: previous.costUSD.doubleValue)
    }
}

// MARK: Token breakdown panel

private struct OverviewTokenBreakdownPanel: View {
    let model: StatsOverviewModel

    /// 命中率大数字用深一档的绿：系统绿在 24pt 大字上过亮。
    private static let hitRateColor = adaptiveColor(light: (30, 127, 58), dark: (48, 209, 88)) // #1E7F3A / #30D158

    var body: some View {
        let totals = model.totalsAll
        Panel(title: "Token breakdown", chinese: "Token 拆分", fillHeight: true) {
            // 不放总 Tokens：与 KPI 卡 1 重复。命中率做大数字，三类分项逐行列出并带占比，
            // Fast 一行贴面板底部。
            VStack(alignment: .leading, spacing: 0) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(Self.hitRatePercent(totals.cacheHitRate))
                        .font(.system(size: 24, weight: .semibold))
                        .kerning(-0.5)
                        .monospacedDigit()
                        .foregroundStyle(Self.hitRateColor)
                    Text(tr("Cache hit rate", "缓存命中率"))
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }

                TokenStackBar(totals: totals)
                    .padding(.top, 12)

                VStack(spacing: 0) {
                    categoryRow(tr("Input", "输入"), tokens: totals.inputTokens, dot: TokenCategoryStyle.input, totals: totals)
                    Divider()
                    categoryRow(tr("Output", "输出"), tokens: totals.outputTokens, dot: TokenCategoryStyle.output, totals: totals)
                    Divider()
                    categoryRow(tr("Cache hit", "缓存命中"), tokens: totals.cacheReadTokens, dot: TokenCategoryStyle.cacheRead, totals: totals)
                }
                .padding(.top, 10)

                Spacer(minLength: 0)

                if model.speedAll.fast.requestCount > 0 {
                    fastLine(model.speedAll)
                        .padding(.top, 12)
                }
            }
        }
    }

    /// 占比分母与堆叠条一致：输入 + 输出 + 缓存命中。
    private func categoryRow(_ label: String, tokens: Int, dot: Double, totals: UsageTotals) -> some View {
        let denominator = totals.inputTokens + totals.outputTokens + totals.cacheReadTokens
        return HStack(spacing: 8) {
            Circle()
                .fill(Color.primary.opacity(dot))
                .frame(width: 8, height: 8)
            Text(label)
                .font(.system(size: 12))
            Spacer(minLength: 8)
            Text(StatsFormatter.compactToken(tokens))
                .font(.system(size: 12.5, weight: .semibold))
                .monospacedDigit()
            Text(StatsFormatter.sharePercent(denominator > 0 ? Double(tokens) / Double(denominator) : 0))
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .monospacedDigit()
                .frame(width: 48, alignment: .trailing)
        }
        .padding(.vertical, 7)
    }

    /// Fast 一行：原始 Tokens · 计费等效 Tokens · 估算费用。
    private func fastLine(_ breakdown: UsageSpeedBreakdown) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Divider()
            HStack(spacing: 6) {
                Image(systemName: "bolt")
                    .font(.system(size: 10, weight: .medium))
                Text(tr(
                    "Fast \(StatsFormatter.compactToken(breakdown.fast.totalTokens)) · equiv. \(StatsFormatter.billingEquivalentTokens(breakdown)) · \(fastCost(breakdown))",
                    "Fast \(StatsFormatter.compactToken(breakdown.fast.totalTokens)) · 等效 \(StatsFormatter.billingEquivalentTokens(breakdown)) · \(fastCost(breakdown))"
                ))
                .font(.system(size: 11))
                .monospacedDigit()
                .lineLimit(1)
            }
            .foregroundStyle(.secondary)
        }
    }

    private func fastCost(_ breakdown: UsageSpeedBreakdown) -> String {
        StatsFormatter.tierCost(
            breakdown.fast.costUSD,
            hasUnpricedUsage: breakdown.fastHasUnpricedCost,
            costIncomplete: breakdown.fast.costIncomplete
        )
    }

    /// 命中率保留一位小数（如 `72.1%`）。
    private static func hitRatePercent(_ rate: Double) -> String {
        String(format: "%.1f%%", max(0, min(1, rate)) * 100)
    }
}

// MARK: Usage chart panel

/// 日 / 周 / 月用量柱状图。悬停选中状态只存在这里：鼠标移动只重绘本面板，
/// 序列、柱宽都由 `StatsOverviewModel` 预先算好，body 里不做聚合；X 轴标签数量
/// 依赖绘图区宽度，在这里用 `StatsOverviewModel.axisKeys(from:maxCount:)` 抽取。
private struct OverviewUsageChartPanel: View {
    @Environment(AppState.self) private var appState
    let model: StatsOverviewModel
    let granularity: StatsGranularity
    let scope: StatsOverviewScope

    @State private var selectedPeriodKey: String?

    var body: some View {
        let selected = selectedPeriodKey.flatMap { model.sample(forKey: $0) }
        Panel(
            title: granularity.panelTitleEnglish,
            chinese: granularity.panelTitleChinese,
            right: AnyView(
                HStack(spacing: 8) {
                    if model.highlightedPeriodStart != nil {
                        Text(tr(granularity.contextWindowHintEnglish, granularity.contextWindowHintChinese))
                            .font(.system(size: 10.5))
                            .foregroundStyle(.tertiary)
                    }
                    ForEach(model.visibleApps, id: \.self) { app in
                        LegendChip(color: app.tintColor, label: app.displayName)
                    }
                }
            ),
            fillHeight: true
        ) {
            VStack(spacing: 6) {
                if model.samples.isEmpty {
                    if appState.usageService.isScanning {
                        loadingPlaceholder(160, message: tr("Recalculating…", "正在计算中…"))
                    } else {
                        placeholderHeight(160, message: tr("No data", "无数据"))
                    }
                } else {
                    chart(selected: selected)
                }
            }
        }
        .onChange(of: scope) { _, _ in selectedPeriodKey = nil }
    }

    private func chart(selected: DailySample?) -> some View {
        let apps = model.visibleApps
        let barWidth = model.barWidth
        let highlighted = model.highlightedPeriodStart
        return Chart {
            ForEach(model.samples) { sample in
                let opacity = Self.barOpacity(for: sample, selected: selected, highlighted: highlighted)
                ForEach(apps, id: \.self) { app in
                    let tokens = sample.totals(for: app).totalTokens
                    // 0 值柱在堆叠里不可见，跳过可以少画一大半 mark（全年日粒度约千根量级）。
                    if tokens > 0 {
                        BarMark(
                            x: .value("Period", sample.key),
                            y: .value("Tokens", Double(tokens)),
                            width: .fixed(barWidth),
                            stacking: .standard
                        )
                        .foregroundStyle(app.tintColor)
                        .opacity(opacity)
                        .cornerRadius(2)
                    }
                }
            }

            if let selected {
                RuleMark(x: .value("Period", selected.key))
                    .foregroundStyle(Color.secondary.opacity(0.25))
                    .lineStyle(StrokeStyle(lineWidth: 1))
            }
        }
        .chartXSelection(value: $selectedPeriodKey)
        .chartXScale(domain: model.samples.map(\.key))
        // X 轴标签自绘：类别很多（长范围日粒度）时内建 AxisMarks 的标签会叠成一片，
        // 所以隐藏内建轴，按绘图区宽度自己抽取刻度并定位到对应柱心。
        .chartXAxis(.hidden)
        // 图表随画布变高后，没有刻度就读不出量级：左侧 3~4 条 Tokens 刻度 + 浅网格线。
        .chartYAxis {
            AxisMarks(position: .leading, values: .automatic(desiredCount: 4)) { value in
                AxisGridLine()
                    .foregroundStyle(Color.secondary.opacity(0.18))
                AxisValueLabel {
                    if let tokens = value.as(Double.self) {
                        Text(StatsFormatter.compactToken(Int(tokens)))
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundStyle(.tertiary)
                    }
                }
            }
        }
        .chartOverlay(alignment: .topLeading) { proxy in
            GeometryReader { geo in
                if let plotFrame = proxy.plotFrame {
                    let plot = geo[plotFrame]
                    ZStack(alignment: .topLeading) {
                        xAxisLabels(proxy: proxy, plot: plot)
                        if let selected {
                            tooltip(for: selected, apps: apps, proxy: proxy, plot: plot, chartSize: geo.size)
                        }
                    }
                }
            }
            .allowsHitTesting(false)
        }
        .padding(.bottom, Self.axisLabelAreaHeight)
        // 理想高 200pt；宽画布下所在一排被拉高时（见 `StatsView.overviewUsageRowMinHeight`）随之变高。
        .frame(minHeight: 180, idealHeight: 200, maxHeight: .infinity)
    }

    /// 标签区高度（含 6pt 上间距），从图表总高里让出，绘图区相应变矮。
    private static let axisLabelAreaHeight: CGFloat = 18
    /// 相邻标签的最小间距；绘图区越宽标签越多，窄时至少保留首尾附近 2 个。
    private static let minAxisLabelSpacing: CGFloat = 80
    /// 单个标签的占位宽度，首尾标签据此收进绘图区内，不被面板边缘截断。
    private static let axisLabelSlotWidth: CGFloat = 64

    /// 悬浮明细贴在选中柱的右侧，右侧放不下时翻到左侧，垂直居中于图表。
    /// 卡片比图表高时也只在上下对称溢出，不再像 `.top` annotation 那样整体伸出图表上方被外层裁掉。
    @ViewBuilder
    private func tooltip(
        for sample: DailySample,
        apps: [UsageApp],
        proxy: ChartProxy,
        plot: CGRect,
        chartSize: CGSize
    ) -> some View {
        if let x = proxy.position(forX: sample.key) {
            let gap = model.barWidth / 2 + 10
            let centerX = plot.minX + x
            let fitsRight = centerX + gap + DailyTooltip.width <= plot.maxX
            let left = fitsRight ? centerX + gap : max(0, centerX - gap - DailyTooltip.width)
            DailyTooltip(sample: sample, visibleApps: apps, granularity: granularity)
                .offset(x: left)
                .frame(width: chartSize.width, height: chartSize.height, alignment: .leading)
        }
    }

    private func xAxisLabels(proxy: ChartProxy, plot: CGRect) -> some View {
        let maxCount = max(2, Int(plot.width / Self.minAxisLabelSpacing))
        let keys = StatsOverviewModel.axisKeys(from: model.samples.map(\.key), maxCount: maxCount)
        let halfSlot = Self.axisLabelSlotWidth / 2
        return ForEach(keys, id: \.self) { key in
            if let x = proxy.position(forX: key),
               let date = StatsPeriodKey.date(from: key) {
                Text(date, format: granularity.axisDateFormat)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .fixedSize()
                    .frame(width: Self.axisLabelSlotWidth)
                    .position(
                        x: min(max(plot.minX + x, plot.minX + halfSlot), plot.maxX - halfSlot),
                        y: plot.maxY + 6 + (Self.axisLabelAreaHeight - 6) / 2
                    )
            }
        }
    }

    /// 悬浮选中某个周期时,非选中柱降透明以聚焦;无悬浮时,上下文窗口内
    /// 只有所选周期那根柱子全彩,前面的上下文柱降透明。
    /// 上下文窗口本身已保证范围只覆盖一个周期,所以直接和该周期起点比,
    /// 自定义范围从周中 / 月中开始时也不会把自己那根柱判成范围外。
    private static func barOpacity(for sample: DailySample, selected: DailySample?, highlighted: Date?) -> Double {
        if let selected {
            return selected.id == sample.id ? 1 : 0.35
        }
        guard let highlighted else { return 1 }
        return sample.day == highlighted ? 1 : 0.35
    }
}

// MARK: Composition panel（用量构成）

extension CompositionDimension {
    @MainActor
    var label: String {
        switch self {
        case .service: return tr("Service", "服务")
        case .provider: return tr("Provider", "提供商")
        case .model: return tr("Model", "模型")
        case .project: return tr("Project", "项目")
        }
    }
}

/// 替代原「按服务 / 按提供商 / 按模型」三个面板：一条占比条 + 一张按排行口径排序的列表，
/// 维度在面板标题右侧切换。列表末列为缓存命中率；输入 / 输出 / 缓存读取明细见 Token 拆分面板。
private struct OverviewCompositionPanel: View {
    let model: StatsOverviewModel
    let scope: StatsOverviewScope
    let onSelectService: (UsageApp) -> Void
    let navigate: (StatsNavigationRequest.Target) -> Void

    @State private var dimension: CompositionDimension = .service
    @State private var expandedProvider: ModelProvider?

    var body: some View {
        let rows = model.composition[dimension] ?? []
        Panel(
            title: "Usage composition",
            chinese: "用量构成",
            right: AnyView(
                SegmentedBar(
                    items: CompositionDimension.allCases,
                    label: { $0.label },
                    selection: $dimension
                )
            ),
            fillHeight: true
        ) {
            if rows.isEmpty || !model.totalsAll.hasUsage {
                placeholderHeight(120, message: emptyMessage)
            } else {
                VStack(alignment: .leading, spacing: 10) {
                    CompositionShareBar(segments: rows.map {
                        CompositionShareBar.Segment(id: $0.id, role: $0.color, share: model.share(of: $0.totals))
                    }, height: 8)

                    VStack(spacing: 0) {
                        columnHeader
                        ScrollView(.vertical) {
                            rowList(rows)
                        }
                        .scrollBounceBehavior(.basedOnSize)
                        .frame(height: Self.listHeight)
                    }

                    // 合计行贴面板底部：行数少（如只有 3 个服务）时留白落在列表与合计之间，面板仍收得住。
                    Spacer(minLength: 0)

                    VStack(spacing: 10) {
                        Divider()
                        HStack(spacing: 8) {
                            Text(tr(
                                "Total \(StatsFormatter.compactToken(model.totalsAll.totalTokens)) tokens · \(StatsFormatter.cost(model.totalsAll.costUSD)) cost",
                                "合计 \(StatsFormatter.compactToken(model.totalsAll.totalTokens)) Tokens · 费用 \(StatsFormatter.cost(model.totalsAll.costUSD))"
                            ))
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                            Spacer(minLength: 8)
                            if dimension == .project {
                                StatsLinkButton(title: tr("All projects ›", "全部项目 ›")) {
                                    navigate(.projectsList)
                                }
                            }
                        }
                    }
                }
            }
        }
        .onChange(of: scope) { _, _ in
            expandedProvider = nil
        }
        .onChange(of: dimension) { _, _ in
            expandedProvider = nil
        }
    }

    /// 列表区固定高度（约 5.8 行双行行高，露出半行提示可滚动），四个维度与提供商展开都在区内滚动，
    /// 面板高度不随维度、行数变化；面板总高约 376pt，低于下排 390pt 下限，切换维度不挤压上方柱状图。
    private static let listHeight: CGFloat = 240

    private func rowList(_ rows: [CompositionRow]) -> some View {
        VStack(spacing: 0) {
            ForEach(Array(rows.enumerated()), id: \.element.id) { index, row in
                if index > 0 { Divider() }
                rowView(row)
            }
        }
    }

    /// 列名行，列宽与 `rowContent` 一致。
    private var columnHeader: some View {
        HStack(spacing: 8) {
            Color.clear.frame(width: 8, height: 1)
            Text(dimension.label)
            Spacer(minLength: 8)
            Text("Tokens").frame(width: 86, alignment: .trailing)
            Text(tr("Cost", "费用")).frame(width: 86, alignment: .trailing)
            Text(tr("Share", "占比")).frame(width: 46, alignment: .trailing)
            Text(tr("Cache hit", "缓存命中率")).frame(width: 64, alignment: .trailing)
            Color.clear.frame(width: 10, height: 1)
        }
        .font(.system(size: 10.5))
        .foregroundStyle(.tertiary)
        .padding(.bottom, 4)
    }

    private var emptyMessage: String {
        if dimension == .service, model.visibleApps.isEmpty {
            return tr("No services turned on · turn one on in Settings → Services & Accounts", "没有开启的服务 · 到「设置 → 服务与账号」开启")
        }
        return tr("No data", "无数据")
    }

    @ViewBuilder
    private func rowView(_ row: CompositionRow) -> some View {
        let isExpanded: Bool = {
            if case .expandProvider(let provider) = row.action { return expandedProvider == provider }
            return false
        }()
        VStack(alignment: .leading, spacing: 0) {
            Group {
                if row.action == .none {
                    rowContent(row, isExpanded: isExpanded)
                } else {
                    Button { perform(row.action) } label: {
                        rowContent(row, isExpanded: isExpanded)
                    }
                    .buttonStyle(.plain)
                    .pointingHandCursor()
                }
            }

            if isExpanded {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(row.providerModels) { item in
                        providerModelRow(item)
                    }
                }
                .padding(.leading, 16)
                .padding(.bottom, 8)
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
    }

    private func rowContent(_ row: CompositionRow, isExpanded: Bool) -> some View {
        // 未归属与不参与排名的灰色行（「其他」提供商、特殊项目）用次级样式。
        let isSecondary = row.kind != .item || row.color == .rest
        return HStack(spacing: 8) {
            CompositionSwatch(role: row.color, size: 8)
            VStack(alignment: .leading, spacing: 1) {
                Text(title(for: row))
                    .font(.system(size: 12.5, weight: isSecondary ? .regular : .semibold))
                    .foregroundStyle(isSecondary ? Color.secondary : Color.primary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                if !subtitle(for: row).isEmpty {
                    PrivacySensitiveText(text: subtitle(for: row), sensitive: row.projectStatus?.isPathBased == true)
                        .font(.system(size: 10.5))
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
            // 名称优先于 Spacer 取宽：长模型名先吃掉空白再截断。
            .layoutPriority(1)
            Spacer(minLength: 8)
            // Tokens 与费用是本面板的主数据：紧跟名称、13pt semibold，比同页 12.5pt 的数值略重；
            // 占比已由顶部占比条表达，与缓存命中率一起降为次级。
            Text("\(StatsFormatter.compactToken(row.totals.totalTokens))")
                .font(.system(size: 13, weight: .semibold))
                .monospacedDigit()
                .frame(width: 86, alignment: .trailing)
            Text(StatsFormatter.tierCost(
                row.totals.costUSD,
                hasUnpricedUsage: row.totals.hasUnpricedUsage,
                costIncomplete: row.totals.costIncomplete
            ))
            .font(.system(size: 13, weight: .semibold))
            .monospacedDigit()
            .frame(width: 86, alignment: .trailing)
            Text(StatsFormatter.percent(model.share(of: row.totals)))
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .monospacedDigit()
                .frame(width: 46, alignment: .trailing)
            Text(hitRateText(row.totals.cacheHitRate))
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .monospacedDigit()
                .frame(width: 64, alignment: .trailing)
            Group {
                switch row.action {
                case .expandProvider:
                    Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                case .openProject, .openUnattributed:
                    Image(systemName: "chevron.right")
                case .selectService, .none:
                    Color.clear
                }
            }
            .font(.system(size: 9, weight: .semibold))
            .foregroundStyle(.tertiary)
            .frame(width: 10, height: 10)
        }
        .padding(.vertical, 6)
        .contentShape(Rectangle())
    }

    private func providerModelRow(_ row: ProviderModelRow) -> some View {
        HStack(spacing: 6) {
            ServiceTile(app: row.app, size: 12)
            Text(row.model)
                .font(.system(size: 11.5, design: .monospaced))
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 8)
            // 数值列与父行的 Tokens / 费用列对齐（同样 8pt 间距），占比、命中率、箭头位留空。
            HStack(spacing: 8) {
                Text(StatsFormatter.compactToken(row.totals.totalTokens))
                    .font(.system(size: 10.5))
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                    .frame(width: 86, alignment: .trailing)
                Text(StatsFormatter.tierCost(
                    row.totals.costUSD,
                    hasUnpricedUsage: row.totals.hasUnpricedUsage,
                    costIncomplete: row.totals.costIncomplete
                ))
                .font(.system(size: 11.5, weight: .semibold))
                .monospacedDigit()
                .frame(width: 86, alignment: .trailing)
                Color.clear.frame(width: 46, height: 1)
                Color.clear.frame(width: 64, height: 1)
                Color.clear.frame(width: 10, height: 1)
            }
        }
    }

    private func title(for row: CompositionRow) -> String {
        switch row.kind {
        case .item:
            switch row.projectStatus {
            case .unassigned: return tr("No project", "无明确项目")
            case .system: return tr("CCBar system tasks", "CCBar 系统任务")
            default:
                if PrivacyDisplay.isEnabled, case .openProject(let key) = row.action {
                    return PrivacyDisplay.project(key)
                }
                return row.title
            }
        case .unattributed:
            return tr("Unattributed", "未归属")
        }
    }

    /// 未归属的说明原先是面板底部单独一行，现在并入该行副标。
    private func subtitle(for row: CompositionRow) -> String {
        switch row.projectStatus {
        case .unassigned: return tr("Started from home or a temporary folder", "从主目录或临时目录启动的对话")
        case .system: return tr("Usage created by CCBar background tasks", "CCBar 后台任务产生的用量")
        default: break
        }
        guard row.kind == .unattributed else { return row.subtitle }
        return tr(
            "Cursor remote, backfilled and early history have no project info",
            "Cursor 远端用量、补录和早期历史，没有项目信息"
        )
    }

    private func perform(_ action: CompositionAction) {
        switch action {
        case .none:
            break
        case .selectService(let app):
            onSelectService(app)
        case .expandProvider(let provider):
            withAnimation(.easeOut(duration: 0.18)) {
                expandedProvider = expandedProvider == provider ? nil : provider
            }
        case .openProject(let key):
            navigate(.project(key))
        case .openUnattributed:
            navigate(.unattributed)
        }
    }
}

// MARK: Top conversations panel（高消耗对话）

private struct OverviewTopConversationsPanel: View {
    let model: StatsOverviewModel
    let navigate: (StatsNavigationRequest.Target) -> Void

    var body: some View {
        let rows = model.topConversations
        Panel(
            title: "Top conversations",
            chinese: "高消耗对话",
            right: AnyView(
                HStack(spacing: 10) {
                    if let share = model.topConversationsShare {
                        Text(model.rankMetric == .tokens
                            ? tr(
                                "Top \(rows.count) = \(StatsFormatter.percent(share)) of tokens",
                                "前 \(rows.count) 个占 Tokens \(StatsFormatter.percent(share))"
                            )
                            : tr(
                                "Top \(rows.count) = \(StatsFormatter.percent(share)) of cost",
                                "前 \(rows.count) 个占费用 \(StatsFormatter.percent(share))"
                            ))
                        .font(.system(size: 10.5))
                        .foregroundStyle(.tertiary)
                        .monospacedDigit()
                    }
                    StatsLinkButton(title: tr("All conversations ›", "全部对话 ›")) {
                        navigate(.conversationsByRank)
                    }
                }
            ),
            fillHeight: true
        ) {
            if rows.isEmpty {
                placeholderHeight(120, message: tr(
                    "No local conversations in this range",
                    "该范围内没有本机对话"
                ))
            } else {
                VStack(spacing: 0) {
                    ForEach(Array(rows.enumerated()), id: \.element.id) { index, row in
                        if index > 0 { Divider() }
                        TopConversationRowView(
                            index: index,
                            row: row,
                            share: model.share(of: row.summary.totals),
                            barRatio: barRatio(row, first: rows.first),
                            roomy: true,
                            metric: model.rankMetric
                        ) {
                            navigate(.conversation(row.id))
                        }
                    }
                }
            }
        }
    }

    private func barRatio(_ row: TopConversationRow, first: TopConversationRow?) -> Double {
        guard let first else { return 0 }
        return StatsRankMetric.ratio(row.rankValue(model.rankMetric), to: first.rankValue(model.rankMetric))
    }
}

/// 高消耗对话的一行，概览与项目页共用。
struct TopConversationRowView: View {
    let index: Int
    let row: TopConversationRow
    /// 占概览 / 项目合计的比例，口径同 `metric`。
    let share: Double
    /// 金额条长度，按第一名归一。
    let barRatio: Double
    var showsProject = true
    /// 概览用：金额条移到标题下方铺满文字列、行距加大，5 行正好填满概览下排。
    var roomy = false
    /// 排行口径：决定右侧大号数字是 Tokens 还是费用，另一项降为次级。
    var metric: StatsRankMetric = .cost
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Text("\(index + 1)")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.tertiary)
                    .frame(width: 14, alignment: .trailing)
                ServiceTile(app: row.summary.info.app, size: 14)
                VStack(alignment: .leading, spacing: 2) {
                    Text(PrivacyDisplay.conversation(row.summary.info))
                        .font(.system(size: 12.5, weight: .medium))
                        .lineLimit(1)
                    Text(metaLine)
                        .font(.system(size: 10.5))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    if roomy {
                        GeometryReader { proxy in
                            amountBar(width: proxy.size.width, height: 3)
                        }
                        .frame(height: 3)
                        .padding(.top, 4)
                    }
                }
                Spacer(minLength: 8)
                if !roomy {
                    amountBar(width: 72, height: 4)
                }
                VStack(alignment: .trailing, spacing: 2) {
                    Text(metric == .tokens ? tokensText : costText)
                        .font(.system(size: 12.5, weight: .semibold))
                        .monospacedDigit()
                    Text("\(metric == .tokens ? costText : tokensText) · \(StatsFormatter.percent(share))")
                        .font(.system(size: 10.5))
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
                .frame(minWidth: 96, alignment: .trailing)
            }
            .padding(.vertical, roomy ? 11 : 6)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .pointingHandCursor()
    }

    /// 金额条：长度按第一名归一。
    private func amountBar(width: CGFloat, height: CGFloat) -> some View {
        ZStack(alignment: .leading) {
            Capsule().fill(Color.secondary.opacity(0.12))
            Capsule()
                .fill(CompositionPalette.amountBar)
                .frame(width: width * max(0, min(1, barRatio)))
        }
        .frame(width: width, height: height)
    }

    private var costText: String { StatsFormatter.cost(row.summary.costs.total) }
    private var tokensText: String { StatsFormatter.compactToken(row.summary.totals.totalTokens) }

    private var metaLine: String {
        var parts: [String] = []
        if showsProject {
            parts.append(StatsProjectLabel.name(row.project))
        }
        if !PrivacyDisplay.isEnabled, let branch = row.summary.info.gitBranch, !branch.isEmpty { parts.append(branch) }
        parts.append(StatsFormatter.day(row.summary.rangeLastAt))
        return parts.joined(separator: " · ")
    }
}

/// 统计页项目名称的统一文案（无明确项目 / 系统任务不用路径名）。
enum StatsProjectLabel {
    @MainActor
    static func name(_ project: StatsProjectIdentity) -> String {
        switch project.status {
        case .unassigned: return tr("No project", "无明确项目")
        case .system: return tr("CCBar system tasks", "CCBar 系统任务")
        case .available, .unavailable, .unverified:
            return PrivacyDisplay.isEnabled ? PrivacyDisplay.project(project.key) : project.name
        }
    }
}

// MARK: Composition primitives（概览与项目页共用）

/// 按配色角色填充：服务识别色 / 紫色色阶 / 其余灰 / 未归属斜纹。
struct CompositionFill: View {
    let role: CompositionColorRole

    var body: some View {
        switch role {
        case .service(let app): app.tintColor
        case .rank(let index): CompositionPalette.rank(index)
        case .rest: CompositionPalette.rest
        case .unattributed: UnattributedStripes()
        }
    }
}

/// 行首色块（≤12pt，圆角 2pt）。
struct CompositionSwatch: View {
    let role: CompositionColorRole
    var size: CGFloat = 8

    var body: some View {
        CompositionFill(role: role)
            .frame(width: size, height: size)
            .clipShape(RoundedRectangle(cornerRadius: 2, style: .continuous))
    }
}

/// 6pt 占比条：按行依次拼接，段间 2pt；占比按总和归一，舍入误差不会让条溢出。
struct CompositionShareBar: View {
    struct Segment {
        let id: String
        let role: CompositionColorRole
        let share: Double
    }

    let segments: [Segment]
    var height: CGFloat = 6

    var body: some View {
        GeometryReader { proxy in
            let visible = segments.filter { $0.share > 0 }
            let total = visible.reduce(0) { $0 + $1.share }
            let spacing: CGFloat = 2
            let available = max(0, proxy.size.width - spacing * CGFloat(max(0, visible.count - 1)))
            HStack(spacing: spacing) {
                ForEach(visible, id: \.id) { segment in
                    CompositionFill(role: segment.role)
                        .frame(width: total > 0 ? max(1, available * segment.share / total) : 0)
                        .clipShape(RoundedRectangle(cornerRadius: 2, style: .continuous))
                }
            }
        }
        .frame(height: height)
    }
}

/// 面板标题右侧的文字链接（「全部对话 ›」等）。
struct StatsLinkButton: View {
    let title: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(Color.accentColor)
        }
        .buttonStyle(.plain)
        .pointingHandCursor()
    }
}

// MARK: Placeholders

private func placeholderHeight(_ height: CGFloat, message: String) -> some View {
    Text(message)
        .font(.system(size: 12))
        .foregroundStyle(.secondary)
        .frame(maxWidth: .infinity)
        .frame(height: height)
}

/// 区分"还在扫描/刷新中"和"确实没有数据"两种空态,避免用户误以为没有记录。
private func loadingPlaceholder(_ height: CGFloat, message: String) -> some View {
    HStack(spacing: 6) {
        ProgressView().controlSize(.small)
        Text(message)
            .font(.system(size: 12))
            .foregroundStyle(.secondary)
    }
    .frame(maxWidth: .infinity)
    .frame(height: height)
}


// MARK: - Panel container

private struct Panel<Content: View>: View {
    let title: String
    let chinese: String
    var right: AnyView? = nil
    /// 并排的两块面板等高：由外层 `StatsSplitRow` 给高度，面板背景撑满。
    var fillHeight = false
    @ViewBuilder var content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                Text(tr(title, chinese))
                    .font(.system(size: 12.5, weight: .semibold))
                Spacer()
                if let right { right }
            }
            content()
        }
        .padding(16)
        .frame(maxWidth: .infinity, maxHeight: fillHeight ? .infinity : nil, alignment: .topLeading)
        .ccPanel(cornerRadius: 12)
    }
}

private struct LegendChip: View {
    let color: Color
    let label: String

    var body: some View {
        HStack(spacing: 5) {
            ServiceMark(color: color, size: 9)
            Text(label)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
        }
    }
}

// MARK: - Segmented bar

/// 自绘分段控件。系统 `Picker(.segmented)` 的段宽只按各自文案自适应,SwiftUI 也没有暴露
/// `NSSegmentedControl.distribution`,所以它既不会拉伸去填满给定宽度,段与段之间也不会等宽。
/// 而 Stats 顶栏要求三个粒度(日 9 段、周 / 月各 6 段)下范围控件总宽一致、和粒度控件之间
/// 不留空隙,系统控件做不到,只能自绘:`stretch` 打开时各段等分容器宽度。
/// 粒度控件一并换成同一组件,避免两个并排的控件一个系统一个自绘、圆角底色对不上。
/// 样式见 设计风格「Segmented control」。
// MARK: - Top bar & filter controls

private extension View {
    /// 上报 ScrollView 是否已离开顶部。滚动几何需要 macOS 15；更早的系统无法检测，
    /// 按已滚动处理（顶栏分隔线一直显示）。
    @ViewBuilder
    func onScrolledPastTop(_ action: @escaping (Bool) -> Void) -> some View {
        if #available(macOS 15.0, *) {
            onScrollGeometryChange(for: Bool.self) { geometry in
                geometry.contentOffset.y + geometry.contentInsets.top > 0
            } action: { _, scrolled in
                action(scrolled)
            }
        } else {
            onAppear { action(true) }
        }
    }
}

/// 统计页顶栏，四个视图共用（`StatsView` 放在页面内容之上，切换视图时不重建）：
/// 左侧标题 + 视图自己的说明 / 扫描状态，选中「自定义」时左侧末尾（紧挨粒度控件）出现起止日期；
/// 右侧粒度 + 范围分段控件，额度页不显示。一行放不下时拆成两行：第一行左侧内容 + 粒度，
/// 第二行范围控件铺满整行。
///
/// 是否换行用 `ViewThatFits` 按理想宽度判断。左侧的理想宽度固定取「最长的视图标题 + 起止日期」，
/// 与当前视图、说明文案、是否选中自定义都无关：同一窗口宽度下各视图行数一致，切换视图、
/// 选中自定义都不会让顶栏在一行 / 两行之间跳。说明文案放不下时截断。
struct StatsTopBar<Detail: View>: View {
    let mode: StatsViewMode
    @Binding var granularity: StatsGranularity
    @Binding var range: StatsRange
    @Binding var customFrom: Date
    @Binding var customTo: Date
    @ViewBuilder var detail: () -> Detail

    private var showsRangeControls: Bool { mode != .quota }

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 12) {
                leading
                if showsRangeControls {
                    // 两个控件固定取理想宽度。HStack 按「剩余宽度 ÷ 剩余子视图数」逐个分配,
                    // 左侧 maxWidth: .infinity 的内容也会分走一份,范围控件拿不到骨架宽度就被压窄,
                    // 「自定义」缩成「自…」。能否放下已由 ViewThatFits 按理想宽度判断过。
                    granularityBar
                    StatsRangePicker(granularity: granularity, range: $range)
                        .fixedSize(horizontal: true, vertical: false)
                }
            }
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 12) {
                    leading
                    if showsRangeControls { granularityBar }
                }
                if showsRangeControls {
                    StatsRangePicker(granularity: granularity, range: $range, fillsWidth: true)
                }
            }
        }
    }

    /// 左侧内容。底下叠一层隐藏的「最长标题 + 起止日期」只撑宽度：理想宽度由它决定，
    /// 实际内容的理想宽度取 0；最小宽度也不小于它，一行布局时标题和日期不会被挤到重叠。
    /// 最小高度 24 与分段控件同高，额度页没有控件时顶栏高度不变。
    private var leading: some View {
        ZStack(alignment: .leading) {
            HStack(spacing: 12) {
                ZStack(alignment: .leading) {
                    ForEach(StatsViewMode.allCases, id: \.self) { titleText($0.title) }
                }
                customDates(from: .constant(Date()), to: .constant(Date()))
            }
            .hidden()

            HStack(spacing: 12) {
                titleText(mode.title)
                detail()
                Spacer(minLength: 0)
                if showsRangeControls, range == .custom {
                    customDates(from: $customFrom, to: $customTo)
                }
            }
            .frame(minWidth: 0, idealWidth: 0, maxWidth: .infinity, alignment: .leading)
        }
        .frame(minHeight: 24)
    }

    private func titleText(_ title: String) -> some View {
        Text(title)
            .font(.system(size: 17, weight: .bold))
            .kerning(-0.4)
            .lineLimit(1)
            .fixedSize()
    }

    private func customDates(from: Binding<Date>, to: Binding<Date>) -> some View {
        HStack(spacing: 6) {
            // 「止」只能晚于「起」；把「起」调到「止」之后时同步推后「止」，
            // 否则 AppKit 只钳制显示、绑定值不变，区间会静默变空。
            DatePicker(tr("From", "起"), selection: Binding(
                get: { from.wrappedValue },
                set: { newValue in
                    from.wrappedValue = newValue
                    if to.wrappedValue < newValue { to.wrappedValue = newValue }
                }
            ), displayedComponents: .date)
            Text("–")
                .foregroundStyle(.secondary)
            DatePicker(tr("To", "止"), selection: to, in: from.wrappedValue..., displayedComponents: .date)
        }
        .labelsHidden()
        .datePickerStyle(.compact)
        .fixedSize()
    }

    private var granularityBar: some View {
        SegmentedBar(items: StatsGranularity.allCases,
                     label: { tr($0.englishLabel, $0.chineseLabel) },
                     selection: $granularity)
            .fixedSize(horizontal: true, vertical: false)
    }
}

/// 范围分段控件。三个粒度的段数不一样(日 9 段,周 / 月各 6 段):若让每组按自己的内容
/// 取宽,切换粒度时控件会忽宽忽窄,并把左边的粒度控件推得左右跳;若只取最宽一组而不
/// 拉伸,周 / 月又会在两个控件之间空出约 3 个段的空隙。
///
/// 这里用段数最多的日粒度那组按自然宽度撑出总宽(`.hidden()`,只参与布局不显示),
/// 当前粒度的控件叠在上面等分填满。于是三个粒度总宽一致、右边缘齐平、与粒度控件之间
/// 没有空隙,代价是周 / 月的 6 段各自更宽——段内都是 2~3 个字,拉宽后仍是正常观感。
/// 宽度由布局系统算,不写死数值,改文案或换语言时自动跟着变。
///
/// `fillsWidth` 用于窄画布的第二行：不再需要骨架，直接铺满整行、各段等分。
struct StatsRangePicker: View {
    let granularity: StatsGranularity
    @Binding var range: StatsRange
    var fillsWidth = false

    var body: some View {
        if fillsWidth {
            bar
        } else {
            SegmentedBar(items: StatsGranularity.day.ranges,
                         label: { tr($0.englishLabel, $0.chineseLabel) },
                         selection: .constant(StatsRange.today),
                         uniformSegments: true)
                .hidden()
                .overlay { bar }
        }
    }

    private var bar: some View {
        SegmentedBar(items: granularity.ranges,
                     label: { tr($0.englishLabel, $0.chineseLabel) },
                     selection: $range,
                     stretch: true)
            .frame(maxWidth: .infinity)
            // 段数随粒度变(9 / 6),不按粒度重建的话 SwiftUI 会跨粒度复用同一批段视图,
            // 把上一个粒度的段宽残留下来,切几次就宽度不一、控件也撑不满而居中留白。
            .id(granularity)
    }
}

/// 列表栏顶部过滤行的搜索框：外观与 `SegmentedBar` 容器同一套（高 24、圆角 7、同底色）。
struct StatsSearchField: View {
    let prompt: String
    @Binding var text: String

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 11))
                .foregroundStyle(.tertiary)
            Group {
                if PrivacyDisplay.isEnabled {
                    SecureField(prompt, text: $text)
                } else {
                    TextField(prompt, text: $text)
                }
            }
            .textFieldStyle(.plain)
            .font(.system(size: 11.5))
        }
        .padding(.horizontal, 8)
        .frame(height: 24)
        .background(
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(colorScheme == .dark ? Color.white.opacity(0.08) : Color.black.opacity(0.06))
        )
    }
}

/// 过滤行里的无边框下拉菜单（排序等）：11.5pt 文案 + 8pt 下拉箭头，高 24。
struct StatsFilterMenu<Item: Hashable>: View {
    let items: [Item]
    let label: (Item) -> String
    @Binding var selection: Item

    var body: some View {
        Menu {
            Picker("", selection: $selection) {
                ForEach(items, id: \.self) { item in
                    Text(label(item)).tag(item)
                }
            }
            .pickerStyle(.inline)
            .labelsHidden()
        } label: {
            HStack(spacing: 5) {
                Text(label(selection))
                    .font(.system(size: 11.5))
                    .lineLimit(1)
                Image(systemName: "chevron.down")
                    .font(.system(size: 8, weight: .semibold))
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 6)
            .frame(height: 24)
            .contentShape(Rectangle())
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .pointingHandCursor()
    }
}

struct SegmentedBar<Item: Hashable>: View {
    let items: [Item]
    let label: (Item) -> String
    @Binding var selection: Item
    /// 各段等分容器宽度(让周 / 月那 6 段撑满日粒度 9 段的宽度);
    /// 关闭时按文案自然宽度,用于撑出宽度骨架。
    var stretch: Bool = false
    /// 骨架专用:每段都按**所有段里最长的那个文案**取宽,于是总宽 = 段数 × 最宽段宽。
    /// 若骨架只取各段自然宽之和,等分后每段拿到的是平均宽,比平均宽的那几段
    /// (中文「30 天」「自定义」)就会被挤到缩字。
    var uniformSegments: Bool = false

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        HStack(spacing: 0) {
            // 身份用 item 自身而不是位置索引:段数随粒度变化,按索引复用会让不同粒度的段
            // 共用同一个视图身份,布局残留在切换后表现为段宽不一。
            ForEach(items, id: \.self) { item in
                segment(item,
                        isFirst: item == items.first,
                        precededBySelected: precedingItem(of: item) == selection)
            }
        }
        .padding(2)
        .background(
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(colorScheme == .dark ? Color.white.opacity(0.08) : Color.black.opacity(0.06))
        )
    }

    /// 段内文案。骨架模式下把所有段的文案叠在一起,宽度取其中最长的那个。
    @ViewBuilder
    private func segmentLabel(_ item: Item, isActive: Bool) -> some View {
        if uniformSegments {
            ZStack {
                ForEach(items, id: \.self) { other in
                    segmentText(label(other), isActive: false)
                }
            }
        } else {
            segmentText(label(item), isActive: isActive)
        }
    }

    private func segmentText(_ text: String, isActive: Bool) -> some View {
        Text(text)
            .font(.system(size: 11.5))
            .lineLimit(1)
            // 骨架已保证每段不窄于最长文案,这里只是兜底,防止窗口被压到极窄时截成省略号。
            .minimumScaleFactor(0.85)
            .foregroundStyle(isActive ? Color.white : Color.primary)
    }

    /// 左邻的那一段,首段返回 nil。段数最多 9 个,线性查找足够。
    private func precedingItem(of item: Item) -> Item? {
        guard let index = items.firstIndex(of: item), index > 0 else { return nil }
        return items[index - 1]
    }

    private func segment(_ item: Item, isFirst: Bool, precededBySelected: Bool) -> some View {
        let isActive = item == selection
        return Button {
            selection = item
        } label: {
            segmentLabel(item, isActive: isActive)
                .padding(.horizontal, 10)
                .frame(maxWidth: stretch ? .infinity : nil)
                .frame(height: 20)
                .background(
                    RoundedRectangle(cornerRadius: 5, style: .continuous)
                        .fill(isActive ? Color.accentColor : Color.clear)
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .focusEffectDisabled()
        .pointingHandCursor()
        .accessibilityAddTraits(isActive ? [.isButton, .isSelected] : .isButton)
        // 段间分隔线:与系统 segmented 一致,只在自己和左邻都未选中时出现。
        .overlay(alignment: .leading) {
            if !isFirst, !isActive, !precededBySelected {
                Rectangle()
                    .fill(Color.primary.opacity(0.12))
                    .frame(width: 1, height: 12)
            }
        }
    }
}

// MARK: - Daily usage tooltip

/// 用量柱状图的悬浮浮层:展示该周期内各服务花费、合计花费与合计 tokens。
private struct DailyTooltip: View {
    static let width: CGFloat = 200

    let sample: DailySample
    let visibleApps: [UsageApp]
    let granularity: StatsGranularity

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(granularity.periodLabel(sample.day))
                .font(.system(size: 11))
                .foregroundStyle(.secondary)

            ForEach(visibleApps, id: \.self) { app in
                serviceRow(color: app.tintColor, label: app.displayName, value: StatsFormatter.tierCost(
                    sample.cost(for: app),
                    hasUnpricedUsage: sample.totals(for: app).hasUnpricedUsage,
                    costIncomplete: sample.totals(for: app).costIncomplete
                ))
            }

            Divider()

            totalRow(label: tr("Total", "合计"), value: StatsFormatter.tierCost(
                sample.totalCost,
                hasUnpricedUsage: sample.totalUsage.hasUnpricedUsage,
                costIncomplete: sample.totalUsage.costIncomplete
            ), emphasized: true)
            totalRow(label: "Tokens", value: StatsFormatter.compactToken(sample.totalTokens), emphasized: true)

            Divider()

            totalRow(label: tr("Input", "输入"), value: StatsFormatter.compactToken(sample.totalUsage.inputTokens), emphasized: false)
            totalRow(label: tr("Output", "输出"), value: StatsFormatter.compactToken(sample.totalUsage.outputTokens), emphasized: false)
            totalRow(label: tr("Cache hit", "缓存命中"), value: StatsFormatter.compactToken(sample.totalUsage.cacheReadTokens), emphasized: false)
            totalRow(label: tr("Hit rate", "命中率"), value: hitRateText(sample.totalUsage.cacheHitRate), emphasized: false)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .frame(width: Self.width, alignment: .leading)
        .fixedSize(horizontal: false, vertical: true)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .ccPanelStroke(cornerRadius: 8)
    }

    private func serviceRow(color: Color, label: String, value: String) -> some View {
        HStack(spacing: 6) {
            ServiceMark(color: color)
            Text(label)
                .font(.system(size: 12))
                .lineLimit(1)
            Spacer(minLength: 8)
            Text(value)
                .font(.system(size: 12, weight: .semibold))
                .monospacedDigit()
                .lineLimit(1)
        }
    }

    private func totalRow(label: String, value: String, emphasized: Bool) -> some View {
        HStack(spacing: 6) {
            Text(label)
                .font(.system(size: emphasized ? 12 : 10.5, weight: emphasized ? .semibold : .regular))
                .lineLimit(1)
            Spacer(minLength: 8)
            Text(value)
                .font(.system(size: emphasized ? 12 : 10.5, weight: emphasized ? .semibold : .regular))
                .monospacedDigit()
                .lineLimit(1)
        }
        .foregroundStyle(emphasized ? .primary : .secondary)
    }
}

// MARK: - KPI card

/// 统计页 KPI 卡，概览与项目页共用。
struct KPICard: View {
    let english: String
    let chinese: String
    let value: String
    let delta: Double?
    let app: UsageApp?
    let dimmed: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            // delta 放在 Label 行右侧：利用标题行原有留白，让 22pt 主值独占整行，
            // 服务变多、卡片被压窄时主值不再被 delta 挤掉。
            HStack(spacing: 4) {
                if let app {
                    ServiceTile(app: app, size: 12)
                }
                // 标签优先于 Spacer 取宽，避免「文字截断、右侧仍留白」；
                // delta 固定理想宽度，卡片过窄时先截标签而不是截百分比。
                Text(tr(english, chinese))
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .layoutPriority(1)
                Spacer(minLength: 6)
                if let delta, delta != 0 {
                    Text(formatDelta(delta))
                        .font(.system(size: 11, weight: .semibold))
                        .monospacedDigit()
                        .foregroundStyle(delta >= 0 ? Color.red : Color.green)
                        .lineLimit(1)
                        .fixedSize()
                }
            }
            // 主值统一 primary；服务识别色只留在标签前的 12pt tile 上（设计风格 §4.2）。
            Text(value)
                .font(.system(size: 22, weight: .semibold))
                .kerning(-0.5)
                .monospacedDigit()
                .foregroundStyle(.primary)
                .lineLimit(1)
                // 最小窗口下 8 张卡每张只剩约 60～110pt，大金额先缩字再截断。
                .minimumScaleFactor(0.75)
        }
        .padding(.vertical, 11)
        .padding(.horizontal, 14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .ccPanel(cornerRadius: 10)
        .opacity(dimmed ? 0.35 : 1)
    }

    private func formatDelta(_ value: Double) -> String {
        let arrow = value >= 0 ? "↑" : "↓"
        let abs = Swift.abs(value)
        return "\(arrow)\(String(format: "%.1f", abs))%"
    }
}

// MARK: - Token breakdown

func hitRateText(_ rate: Double) -> String {
    "\(Int((max(0, min(1, rate)) * 100).rounded()))%"
}

enum TokenCategoryStyle {
    static let input = 0.85
    static let output = 0.6
    static let cacheRead = 0.4
}

/// 输入 / 输出 / 缓存命中 三段迷你堆叠条,风格延续 `ProgressBar`(Capsule + 灰底轨道)。
struct TokenStackBar: View {
    let totals: UsageTotals
    var height: CGFloat = 8

    private var segments: [(tokens: Int, opacity: Double)] {
        [
            (totals.inputTokens, TokenCategoryStyle.input),
            (totals.outputTokens, TokenCategoryStyle.output),
            (totals.cacheReadTokens, TokenCategoryStyle.cacheRead)
        ]
    }

    private var total: Int { segments.reduce(0) { $0 + $1.tokens } }

    var body: some View {
        GeometryReader { proxy in
            HStack(spacing: 0) {
                ForEach(Array(segments.enumerated()), id: \.offset) { _, segment in
                    Color.primary.opacity(segment.opacity)
                        .frame(width: proxy.size.width * ratio(segment.tokens))
                }
            }
        }
        .frame(height: height)
        .background(Color.secondary.opacity(0.18))
        .clipShape(Capsule())
    }

    private func ratio(_ tokens: Int) -> Double {
        guard total > 0 else { return 0 }
        return Double(tokens) / Double(total)
    }
}

// MARK: - Quota timeline

private struct QuotaTimelineAccountPanel: View {
    let section: QuotaTimelineSection
    /// 全局选定的窗口视角，所有账号使用同一口径。
    let selectedKind: QuotaLimitKind
    /// 折线图固定高度（见 `StatsView.quotaTimelineChartHeight`），展开变动明细不影响图高。
    let chartHeight: CGFloat

    /// 变动明细默认收起，保证额度页在默认窗口内一屏看完。
    @State private var showsDetails = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header
            if let window = activeWindow {
                windowContent(window)
            } else {
                loadingOrEmpty(message: tr("No data for this window", "该窗口暂无数据"))
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .ccPanel(cornerRadius: 12)
    }

    /// 当前 Picker 是全局语义；无对应数据时保留空态，不能悄悄回退到另一种窗口。
    private var activeWindow: QuotaTimelineWindow? {
        section.windows.first { $0.kind == selectedKind }
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            HStack(spacing: 7) {
                ServiceTile(app: section.app, size: 14)
                    .alignmentGuide(.firstTextBaseline) { $0[VerticalAlignment.center] + 4.5 }
                Text(section.title)
                    .font(.system(size: 13, weight: .semibold))
                if let kind = activeWindow?.kind {
                    Text(limitKindLabel(kind))
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Color.secondary.opacity(0.1), in: Capsule())
                }
            }
            Spacer()
            if let window = activeWindow {
                timelineMetric(
                    label: tr("Remaining", "剩余"),
                    value: currentText(window),
                    color: statusColor(remainingPercent: window.currentRemaining.map { Double($0) }, tint: section.tint)
                )
                timelineMetric(
                    label: deltaLabel(window.kind),
                    value: StatsFormatter.quotaDelta(window.periods.first?.totalDelta ?? 0)
                )
                timelineMetric(label: tr("Updated", "更新"), value: latestText(window))
            }
        }
    }

    private func limitKindLabel(_ kind: QuotaLimitKind) -> String {
        switch kind {
        case .fiveHour: return "5H"
        case .weekly: return "WK"
        case .modelWeekly: return tr("MODEL", "模型")
        case .unknown: return tr("CURRENT", "当前")
        }
    }

    /// `color` 只有「当前」传剩余状态色，其余指标保持 secondary。
    private func timelineMetric(label: String, value: String, color: Color = .secondary) -> some View {
        VStack(alignment: .trailing, spacing: 1) {
            Text(label)
                .font(.system(size: 9.5))
                .foregroundStyle(.tertiary)
            Text(value)
                .font(.system(size: 11.5, weight: .medium, design: .monospaced))
                .foregroundStyle(color)
        }
    }

    private func currentText(_ window: QuotaTimelineWindow) -> String {
        guard let value = window.currentRemaining else { return "--" }
        return "\(value)%"
    }

    private func deltaLabel(_ kind: QuotaLimitKind) -> String {
        switch kind {
        case .fiveHour: return tr("Today", "今天")
        case .weekly: return tr("Current cycle", "当前周期")
        case .modelWeekly, .unknown: return tr("Change", "变动")
        }
    }

    /// 5H 视图只画今天，但最新采样可能停在昨天（今天还没刷新成功）；这时必须带日期，
    /// 否则纯 `HH:mm` 会被读成今天的时间。
    private func latestText(_ window: QuotaTimelineWindow) -> String {
        guard let date = window.latestSampleAt else { return "--" }
        let spansDays = window.kind == .weekly || !Calendar.current.isDateInToday(date)
        return StatsFormatter.timelineTime(date, spansDays: spansDays)
    }

    @ViewBuilder
    private func windowContent(_ window: QuotaTimelineWindow) -> some View {
        let entries = mergedEntries(in: window)

        VStack(alignment: .leading, spacing: 8) {
            ForEach(window.periods) { period in
                periodSummary(period, window: window)
            }
        }

        if entries.isEmpty {
            loadingOrEmpty(message: tr("No data for this window", "该窗口暂无数据"))
                .frame(height: 80)
        } else {
            timelineChart(entries, window: window)
                .frame(height: chartHeight)

            let changeCount = entries.filter { $0.deltaPercent != nil }.count
            Button {
                withAnimation(.easeOut(duration: 0.18)) { showsDetails.toggle() }
            } label: {
                HStack(spacing: 5) {
                    Image(systemName: showsDetails ? "chevron.down" : "chevron.right")
                        .font(.system(size: 9, weight: .semibold))
                        .frame(width: 10)
                    Text(tr("Change details · \(changeCount)", "变动明细 · \(changeCount) 条"))
                        .font(.system(size: 11.5, weight: .medium))
                    Spacer()
                }
                .foregroundStyle(.secondary)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .pointingHandCursor()

            if showsDetails {
                QuotaTimelineTable(entries: entries, spansDays: window.kind == .weekly)
                    .transition(.opacity)
            }
        }
    }

    /// 周视图的当前/上一周期共用一张图和一张表；合并时给每个周期的窗口序号加偏移，
    /// 保留跨额度窗口断线语义，不把不同周期的最后一点和第一点连成假回升。
    private func mergedEntries(in window: QuotaTimelineWindow) -> [QuotaTimelineEntry] {
        var result: [QuotaTimelineEntry] = []
        var windowIndexOffset = 0

        for period in window.periods {
            let periodEntries = period.entries
            result.append(contentsOf: periodEntries.map { entry in
                var merged = entry
                merged.windowIndex += windowIndexOffset
                return merged
            })

            let periodWindowCount = (periodEntries.map(\.windowIndex).max() ?? -1) + 1
            windowIndexOffset += periodWindowCount
        }

        return result.sorted { $0.sampledAt < $1.sampledAt }
    }

    private func periodSummary(_ period: QuotaTimelinePeriod, window: QuotaTimelineWindow) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(periodLabel(period.kind))
                .font(.system(size: 11.5, weight: .semibold))
                .foregroundStyle(.secondary)
            Text("\(StatsFormatter.timelineTime(period.start, spansDays: window.kind == .weekly)) → \(StatsFormatter.timelineTime(period.end, spansDays: window.kind == .weekly))")
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(.tertiary)
            Spacer()
            Text(StatsFormatter.quotaDelta(period.totalDelta))
                .font(.system(size: 10.5, weight: .medium, design: .monospaced))
                .foregroundStyle(.secondary)
        }
    }

    private func timelineChart(
        _ entries: [QuotaTimelineEntry],
        window: QuotaTimelineWindow
    ) -> some View {
        QuotaTimelineChart(
            entries: entries,
            tint: section.tint,
            spansDays: window.kind == .weekly,
            domain: timelineDomain(for: window),
            resetAt: windowResetTime(for: window, entries: entries)
        )
    }

    /// 「窗口重置」参考线：5H 取当前窗口的起点（下次重置 − 5 小时），
    /// 周视图取当前周期起点。都晚于现在或推不出时不画。
    /// 快照过期、已知的下次重置已经过去时，5H 窗口从首次使用起算、没有固定网格，
    /// 无法推出当前窗口，只画最近一次确知发生的重置时刻。
    private func windowResetTime(for window: QuotaTimelineWindow, entries: [QuotaTimelineEntry]) -> Date? {
        let now = Date()
        switch window.kind {
        case .fiveHour:
            guard let next = window.resetsAt ?? entries.last(where: { $0.resetsAt != nil })?.resetsAt else { return nil }
            var start = next <= now ? next : next.addingTimeInterval(-5 * 3600)
            while start > now { start.addTimeInterval(-5 * 3600) }
            return Calendar.current.isDate(start, inSameDayAs: now) ? start : nil
        case .weekly:
            return window.periods.first(where: { $0.kind == .currentCycle })?.start
        case .modelWeekly, .unknown:
            return nil
        }
    }

    private func timelineDomain(for window: QuotaTimelineWindow) -> ClosedRange<Date> {
        guard let start = window.periods.map(\.start).min(),
              let end = window.periods.map(\.end).max()
        else {
            let now = Date()
            return now...now.addingTimeInterval(1_800)
        }
        return start...max(start, end)
    }

    private func periodLabel(_ kind: QuotaTimelinePeriodKind) -> String {
        switch kind {
        case .today: return tr("Today", "今天")
        case .currentCycle: return tr("Current cycle", "当前周期")
        case .previousCycle: return tr("Previous cycle", "上一周期")
        }
    }

    @ViewBuilder
    private func loadingOrEmpty(message: String) -> some View {
        if section.isLoading {
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text(tr("Loading…", "加载中…"))
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            Text(message)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

/// 窗口切换分段的可选项；固定 5H → 每周顺序。
@MainActor
private enum QuotaTimelineWindowKind: Hashable {
    case fiveHour
    case weekly

    var kind: QuotaLimitKind {
        switch self {
        case .fiveHour: return .fiveHour
        case .weekly: return .weekly
        }
    }

    var label: String {
        switch self {
        case .fiveHour: return tr("5H", "5小时")
        case .weekly: return tr("WK", "本周")
        }
    }

    static let pickable: [QuotaTimelineWindowKind] = [.fiveHour, .weekly]
}

private struct QuotaTimelineChart: View {
    let entries: [QuotaTimelineEntry]
    let tint: Color
    var spansDays: Bool = false
    let domain: ClosedRange<Date>
    /// 「窗口重置」竖线；nil 不画。
    var resetAt: Date?
    /// 「现在」竖线，放进域里保证可见。
    var now = Date()

    /// X 轴按实际数据范围自适应，不再固定成整段周期：一天/一周里只有少数几次变动时，
    /// 固定域会把所有点挤在很窄的一段。两端各留一点余量，避免首尾点贴着轴；
    /// 单点或零跨度时退回固定余量，防止退化成零宽度域。
    private var xDomain: ClosedRange<Date> {
        let times = entries.map(\.sampledAt) + [now] + (resetAt.map { [$0] } ?? [])
        guard let first = times.min(), let last = times.max() else { return domain }
        let span = last.timeIntervalSince(first)
        let padding = span > 0 ? span * 0.04 : (spansDays ? 1_800 : 900)
        return first.addingTimeInterval(-padding)...last.addingTimeInterval(padding)
    }

    var body: some View {
        Chart {
            ForEach(entries) { entry in
                // series 按额度窗口分段：跨窗重置不产生变动事件，不分段会把上一窗口的低点
                // 和新窗口的高点直连成一条「额度自己涨回去」的假斜线。
                LineMark(
                    x: .value("Time", entry.sampledAt),
                    y: .value("Remaining", entry.remainingPercent),
                    series: .value("Window", entry.windowIndex)
                )
                .foregroundStyle(tint)
                .lineStyle(StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))

                PointMark(
                    x: .value("Time", entry.sampledAt),
                    y: .value("Remaining", entry.remainingPercent)
                )
                .foregroundStyle(chartPointColor(remainingPercent: Double(entry.remainingPercent)))
                .symbolSize(40)
            }

            if let resetAt {
                RuleMark(x: .value("Time", resetAt))
                    .foregroundStyle(Color.secondary.opacity(0.45))
                    .lineStyle(StrokeStyle(lineWidth: 1, dash: [3, 3]))
                    .annotation(position: .top, alignment: .leading, spacing: 2) {
                        referenceLabel(tr("Window reset", "窗口重置"))
                    }
            }
            RuleMark(x: .value("Time", now))
                .foregroundStyle(Color.secondary.opacity(0.45))
                .lineStyle(StrokeStyle(lineWidth: 1))
                .annotation(position: .top, alignment: .trailing, spacing: 2) {
                    referenceLabel(tr("Now", "现在"))
                }
        }
        .chartYScale(domain: 0...100)
        .chartXScale(domain: xDomain)
        .chartXAxis {
            AxisMarks(values: .automatic(desiredCount: 5)) { value in
                AxisGridLine()
                    .foregroundStyle(.secondary.opacity(0.18))
                if spansDays {
                    AxisValueLabel(format: .dateTime.month(.twoDigits).day(.twoDigits).hour(.twoDigits(amPM: .omitted)).minute(.twoDigits))
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(.secondary)
                } else {
                    AxisValueLabel(format: .dateTime.hour().minute())
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(.secondary)
                }
            }
        }
        .chartYAxis {
            AxisMarks(position: .leading, values: [0, 20, 50, 80, 100]) { value in
                AxisGridLine()
                    .foregroundStyle(.secondary.opacity(0.18))
                AxisValueLabel {
                    if let intValue = value.as(Int.self) {
                        Text("\(intValue)%")
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
        // 左:Y 轴刻度不贴面板内容左缘;右:末尾数据点 / X 轴标签不贴相邻表格。
        .padding(.leading, 12)
        .padding(.trailing, 8)
    }

    private func referenceLabel(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 9.5))
            .foregroundStyle(.tertiary)
            .fixedSize()
    }

    /// 图表内数据点 3 档色:low / empty 沿用全局 `statusColor`;
    /// normal(>=20%)档在图表内比全局中性灰加深一档,保证浅色模式下点的可读性。
    /// 全局 `statusColor` 与 Popover / HUD 等处的中性灰不受影响。
    private func chartPointColor(remainingPercent: Double) -> Color {
        guard remainingPercent >= 20 else {
            return statusColor(remainingPercent: remainingPercent, tint: .secondary)
        }
        return Color(nsColor: NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            let rgb: (red: CGFloat, green: CGFloat, blue: CGFloat) = isDark
                ? (174, 174, 180)  // #AEAEB4
                : (86, 86, 90)     // #56565A
            return NSColor(
                calibratedRed: rgb.red / 255,
                green: rgb.green / 255,
                blue: rgb.blue / 255,
                alpha: 1
            )
        })
    }
}

private struct QuotaTimelineTable: View {
    let entries: [QuotaTimelineEntry]
    var spansDays: Bool = false

    /// 行数超过该值时,表体固定高度内部滚动(表头固定),保证面板高度稳定。
    private static let maxVisibleRows = 8
    /// 单行高度估算:11.5pt 行文本(~14pt)+ 上下 7pt padding + Divider。
    private static let rowHeight: CGFloat = 29

    private var rows: [QuotaTimelineEntry] {
        entries.sorted { $0.sampledAt > $1.sampledAt }
    }

    var body: some View {
        VStack(spacing: 0) {
            headerRow
            if rows.count > Self.maxVisibleRows {
                ScrollView {
                    VStack(spacing: 0) {
                        rowsBody
                    }
                }
                .frame(height: CGFloat(Self.maxVisibleRows) * Self.rowHeight)
            } else {
                rowsBody
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(Color.secondary.opacity(0.14), lineWidth: 0.5)
        )
    }

    @ViewBuilder
    private var rowsBody: some View {
        ForEach(rows) { entry in
            Divider()
            row(entry)
        }
    }

    private var headerRow: some View {
        HStack {
            tableHeader("Time", "时间", width: 82, alignment: .leading)
            tableHeader("Change", "变动值", width: 82, alignment: .trailing)
            tableHeader("After", "变动后剩余", width: 104, alignment: .trailing)
            tableHeader("Reset", "重置时间", width: 96, alignment: .trailing)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(Color.secondary.opacity(0.06))
    }

    private func row(_ entry: QuotaTimelineEntry) -> some View {
        HStack {
            tableText(StatsFormatter.timelineTime(entry.sampledAt, spansDays: spansDays), width: 82, alignment: .leading)
            tableText(entry.deltaPercent.map { StatsFormatter.quotaDelta($0) } ?? "—", width: 82, alignment: .trailing)
                .foregroundStyle(deltaColor(entry.deltaPercent))
            tableText("\(entry.remainingPercent)%", width: 104, alignment: .trailing)
                .foregroundStyle(statusColor(remainingPercent: Double(entry.remainingPercent), tint: .secondary))
            tableText(StatsFormatter.resetTime(entry.resetsAt, spansDays: spansDays), width: 96, alignment: .trailing)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
    }

    private func deltaColor(_ value: Int?) -> Color {
        guard let value else { return .secondary }
        return value < 0 ? .red : .green
    }

    private func tableHeader(
        _ english: String,
        _ chinese: String,
        width: CGFloat,
        alignment: Alignment
    ) -> some View {
        Text(tr(english, chinese))
            .font(.system(size: 10.5, weight: .semibold))
            .foregroundStyle(.tertiary)
            .frame(width: width, alignment: alignment)
    }

    private func tableText(_ text: String, width: CGFloat, alignment: Alignment) -> some View {
        Text(text)
            .font(.system(size: 11.5, design: .monospaced))
            .foregroundStyle(.secondary)
            .frame(width: width, alignment: alignment)
    }
}

// MARK: - Timeline row models

private struct QuotaTimelineSection: Identifiable {
    var id: String { accountKey }
    let accountKey: String
    let title: String
    let app: UsageApp
    var tint: Color { app.tintColor }
    let windows: [QuotaTimelineWindow]
    var isLoading: Bool = false
}

/// 单个标准窗口（5H / 每周）的时间线数据。5H 仅含今天；周窗口含当前和上一额度周期。
private struct QuotaTimelineWindow: Identifiable {
    var id: QuotaLimitKind { kind }
    let kind: QuotaLimitKind
    let currentRemaining: Int?
    let latestSampleAt: Date?
    /// 快照里的下次重置时间，画「窗口重置」参考线用。
    let resetsAt: Date?
    let periods: [QuotaTimelinePeriod]
}

// MARK: - Formatter

enum StatsFormatter {
    /// 固定小数位的金额 / 数量格式器。统计页每次刷新要格式化上百个数字，
    /// 每次调用都新建 `NumberFormatter` 开销不小，这里按配置各建一个复用。
    private static func decimalFormatter(minimumFractionDigits: Int?, maximumFractionDigits: Int?) -> NumberFormatter {
        let f = NumberFormatter()
        f.numberStyle = .decimal
        f.locale = Locale(identifier: "en_US_POSIX")
        f.groupingSeparator = ","
        if let minimumFractionDigits { f.minimumFractionDigits = minimumFractionDigits }
        if let maximumFractionDigits { f.maximumFractionDigits = maximumFractionDigits }
        return f
    }

    private static let costFormatter = decimalFormatter(minimumFractionDigits: 2, maximumFractionDigits: 2)
    private static let costWholeFormatter = decimalFormatter(minimumFractionDigits: 0, maximumFractionDigits: 0)
    private static let costPreciseFormatter = decimalFormatter(minimumFractionDigits: 4, maximumFractionDigits: 6)
    private static let tokenFormatter = decimalFormatter(minimumFractionDigits: nil, maximumFractionDigits: nil)

    static func cost(_ value: Decimal) -> String {
        let ns = NSDecimalNumber(decimal: value)
        return "$\(costFormatter.string(from: ns) ?? "0.00")"
    }

    /// 美元显示取整（四舍五入到整数），仅周期页面使用，存储仍用原始 Decimal。
    static func costWhole(_ value: Decimal) -> String {
        let ns = NSDecimalNumber(decimal: value)
            .rounding(accordingToBehavior: nil)
        return "$\(costWholeFormatter.string(from: ns) ?? "0")"
    }

    static func costPrecise(_ value: Decimal) -> String {
        let ns = NSDecimalNumber(decimal: value)
        return "$\(costPreciseFormatter.string(from: ns) ?? "0.0000")"
    }

    /// 图表 Y 轴专用：正常金额保持紧凑，小额刻度保留足够小数避免全部显示为 $0。
    static func axisCost(_ value: Decimal) -> String {
        let ns = NSDecimalNumber(decimal: value)
        let magnitude = abs(ns.doubleValue)
        let f = NumberFormatter()
        f.numberStyle = .decimal
        f.locale = Locale(identifier: "en_US_POSIX")
        f.groupingSeparator = ","
        if magnitude >= 10 {
            f.minimumFractionDigits = 0
            f.maximumFractionDigits = 0
        } else if magnitude >= 1 {
            f.minimumFractionDigits = 2
            f.maximumFractionDigits = 2
        } else {
            f.minimumFractionDigits = 2
            f.maximumFractionDigits = 3
        }
        return "$\(f.string(from: ns) ?? "0.00")"
    }

    @MainActor
    static func tierCost(
        _ value: Decimal,
        hasUnpricedUsage _: Bool,
        costIncomplete _: Bool = false
    ) -> String {
        return cost(value)
    }

    /// 取整版 tierCost：仅周期页面使用。
    @MainActor
    static func tierCostWhole(_ value: Decimal, hasUnpricedUsage _: Bool) -> String {
        return costWhole(value)
    }

    @MainActor
    static func tierCostPrecise(_ value: Decimal, hasUnpricedUsage _: Bool) -> String {
        return costPrecise(value)
    }

    @MainActor
    static func billingEquivalentTokens(_ breakdown: UsageSpeedBreakdown) -> String {
        compactToken(breakdown.fastBillingEquivalentTokens)
    }

    @MainActor
    static func fastMultiplier(_ breakdown: UsageSpeedBreakdown) -> String {
        guard !breakdown.hasUnpricedFastEquivalent else { return "—" }
        guard let minimum = breakdown.fastMinimumMultiplier,
              let maximum = breakdown.fastMaximumMultiplier else {
            return "—"
        }
        return minimum == maximum
            ? "\(minimum.asPlainString)×"
            : "\(minimum.asPlainString)–\(maximum.asPlainString)×"
    }

    static func token(_ value: Int) -> String {
        tokenFormatter.string(from: NSNumber(value: value)) ?? "\(value)"
    }

    /// 分项占比保留一位小数；非零但不足 0.1% 显示 `<0.1%`。
    static func sharePercent(_ ratio: Double) -> String {
        guard ratio.isFinite, ratio > 0 else { return "0%" }
        let value = ratio * 100
        return value < 0.1 ? "<0.1%" : String(format: "%.1f%%", min(100, value))
    }

    /// 紧凑显示。中文用 万 / 亿,英文用 k / M / B。
    /// zh:  6772.37 万  /  1.23 亿  /  1,234
    /// en:  67.7M  /  248.3k  /  1,234
    @MainActor
    static func compactToken(_ value: Int) -> String {
        let v = Double(value)
        switch L10n.current {
        case .zh:
            if v >= 100_000_000 {
                return "\(trimTrailingZeros(v / 100_000_000)) 亿"
            }
            if v >= 10_000 {
                return "\(trimTrailingZeros(v / 10_000)) 万"
            }
            return token(value)
        case .en:
            if v >= 1_000_000_000 {
                return String(format: "%.2fB", v / 1_000_000_000)
            }
            if v >= 1_000_000 {
                return String(format: "%.2fM", v / 1_000_000)
            }
            if v >= 1_000 {
                return String(format: "%.1fk", v / 1_000)
            }
            return "\(value)"
        }
    }

    @MainActor
    static func compactToken(_ value: Decimal) -> String {
        let rounded = NSDecimalNumber(decimal: value).doubleValue.rounded()
        if rounded >= Double(Int.max) { return "—" }
        return compactToken(Int(rounded))
    }

    /// 保留两位小数,去掉末尾多余的 0(如 6772.30 → 6772.3,1234.00 → 1234)。
    private static func trimTrailingZeros(_ value: Double) -> String {
        let s = String(format: "%.2f", value)
        var trimmed = s
        if trimmed.contains(".") {
            while trimmed.hasSuffix("0") { trimmed.removeLast() }
            if trimmed.hasSuffix(".") { trimmed.removeLast() }
        }
        return trimmed
    }

    private static let dayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    static func day(_ date: Date) -> String {
        dayFormatter.string(from: date)
    }

    private static let monthDayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "MM-dd"
        return f
    }()

    private static let monthFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM"
        return f
    }()

    /// 周桶标题:起始日全写、结束日省年份,控制在 200pt 浮层宽度内(如 `2026-09-01 – 09-07`)。
    static func weekRange(_ start: Date) -> String {
        let end = StatsRange.weekStartMondayCalendar.date(byAdding: .day, value: 6, to: start) ?? start
        return "\(day(start)) – \(monthDayFormatter.string(from: end))"
    }

    /// 左闭右开区间的日期范围：单日 `2026-09-28`,同年 `2026-08-30 至 09-28`,跨年两端都带年份。
    @MainActor
    static func dayRange(from: Date, toExclusive: Date) -> String {
        let cal = StatsRange.weekStartMondayCalendar
        let last = cal.startOfDay(for: toExclusive.addingTimeInterval(-1))
        let first = cal.startOfDay(for: from)
        if last <= first { return day(first) }
        let end = cal.component(.year, from: first) == cal.component(.year, from: last)
            ? monthDayFormatter.string(from: last)
            : day(last)
        return tr("\(day(first)) – \(end)", "\(day(first)) 至 \(end)")
    }

    /// 月桶标题(如 `2026-09`)。
    static func month(_ start: Date) -> String {
        monthFormatter.string(from: start)
    }

    private static let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "HH:mm"
        return f
    }()

    static func time(_ date: Date) -> String {
        timeFormatter.string(from: date)
    }

    private static let resetTimeWithDayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "MM-dd HH:mm"
        return f
    }()

    static func resetTime(_ date: Date?) -> String {
        guard let date else { return "--" }
        return time(date)
    }

    static func resetTime(_ date: Date?, spansDays: Bool) -> String {
        guard let date else { return "--" }
        return timelineTime(date, spansDays: spansDays)
    }

    /// 时间线使用的时刻格式：同一窗口跨天（滚动周窗口 / 跨午夜 5H）时带 MM-dd 前缀。
    static func timelineTime(_ date: Date, spansDays: Bool) -> String {
        spansDays ? resetTimeWithDayFormatter.string(from: date) : time(date)
    }

    /// 占比文案：取整百分比；大于 0 但不足 1% 时显示「<1%」，避免有用量却显示 0%。
    static func percent(_ ratio: Double) -> String {
        guard ratio.isFinite, ratio > 0 else { return "0%" }
        let value = Int((ratio * 100).rounded())
        return value == 0 ? "<1%" : "\(min(100, value))%"
    }

    static func quotaDelta(_ value: Int) -> String {
        if value > 0 { return "+\(value)%" }
        return "\(value)%"
    }
}

// MARK: - Decimal helper

private extension Decimal {
    var doubleValue: Double {
        NSDecimalNumber(decimal: self).doubleValue
    }
}
